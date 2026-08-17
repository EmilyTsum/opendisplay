import Foundation

/// Best-effort negotiated USB link information for the physical iPhone/iPad
/// behind a usbmux connection. The data path still runs through usbmuxd; this
/// only answers what speed macOS says the USB device itself enumerated at.
///
/// `system_profiler` is intentionally queried only on USB connect/reconnect,
/// never on the capture path. Its JSON schema has changed slightly across
/// macOS releases, so the parser matches the device by serial/UDID and then
/// searches that device node for a human-readable speed rather than relying on
/// one private JSON key.
struct USBLinkInfo: Equatable, Sendable {
    let megabitsPerSecond: Int

    var speedLabel: String {
        if megabitsPerSecond >= 1_000 {
            let gbps = Double(megabitsPerSecond) / 1_000
            return gbps.rounded() == gbps
                ? "\(Int(gbps)) Gb/s"
                : String(format: "%.1f Gb/s", gbps)
        }
        return "\(megabitsPerSecond) Mb/s"
    }

    /// Avoid guessing the marketing revision (USB 3.0 vs 3.1/3.2 naming is
    /// notoriously ambiguous); the negotiated line rate is the useful fact.
    var hudLabel: String {
        megabitsPerSecond == 480
            ? "USB 2 · \(speedLabel)"
            : "USB · \(speedLabel)"
    }

    /// Runs `system_profiler` off the sender queue and returns the negotiated
    /// speed for the device. Prefer the stable usbmux UDID, but also carry the
    /// USB topology LocationID: some macOS/device combinations omit or rewrite
    /// the iOS UDID in SPUSBDataType even though the location is still exposed.
    static func detect(udid: String, locationID: Int? = nil) async -> USBLinkInfo? {
        await Task.detached(priority: .utility) {
            detectSynchronously(udid: udid, locationID: locationID)
        }.value
    }

    static func detectSynchronously(udid: String, locationID: Int? = nil) -> USBLinkInfo? {
        // Prefer JSON because it is locale-independent. Some macOS releases,
        // however, omit the device speed from SPUSBDataType's JSON while the
        // human-readable report still contains `Speed: Up to …`. Fall back to
        // that report before giving up so the HUD never depends on one schema.
        if let info = detectJSON(udid: udid, locationID: locationID) { return info }
        return detectText(udid: udid, locationID: locationID)
    }

    private static func detectJSON(udid: String, locationID: Int?) -> USBLinkInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPUSBDataType", "-json", "-detailLevel", "full"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parse(profile: root, udid: udid, locationID: locationID)
    }

    private static func detectText(udid: String, locationID: Int?) -> USBLinkInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPUSBDataType", "-detailLevel", "full"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return parseText(profile: text, udid: udid, locationID: locationID)
    }

    /// Exposed to the hostless Mac test target so schema/key variations can be
    /// covered without needing a physical USB device in CI.
    static func parse(profile: Any, udid: String, locationID: Int? = nil) -> USBLinkInfo? {
        let wanted = normalizeIdentifier(udid)
        let device = (!wanted.isEmpty ? findDeviceNode(in: profile, matching: wanted) : nil)
            ?? locationID.flatMap { findDeviceNode(in: profile, locationID: $0) }
        guard let device,
              let mbps = findSpeed(in: device) else { return nil }
        return USBLinkInfo(megabitsPerSecond: mbps)
    }

    private static func findDeviceNode(in value: Any, matching wanted: String) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            // Prefer fields whose name explicitly looks serial-ish, but accept
            // an exact identifier anywhere in the node for forward-compatible
            // system_profiler schemas.
            for (key, raw) in dict {
                guard let string = raw as? String else { continue }
                let normalized = normalizeIdentifier(string)
                if normalized == wanted,
                   key.lowercased().contains("serial") || key.lowercased().contains("udid") {
                    return dict
                }
            }
            for raw in dict.values {
                if let string = raw as? String, normalizeIdentifier(string) == wanted {
                    return dict
                }
            }
            for raw in dict.values {
                if let found = findDeviceNode(in: raw, matching: wanted) { return found }
            }
        } else if let array = value as? [Any] {
            for raw in array {
                if let found = findDeviceNode(in: raw, matching: wanted) { return found }
            }
        }
        return nil
    }

    private static func findDeviceNode(in value: Any, locationID wanted: Int) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            for (key, raw) in dict where key.lowercased().contains("location") {
                if locationID(from: raw) == wanted { return dict }
            }
            for raw in dict.values {
                if let found = findDeviceNode(in: raw, locationID: wanted) { return found }
            }
        } else if let array = value as? [Any] {
            for raw in array {
                if let found = findDeviceNode(in: raw, locationID: wanted) { return found }
            }
        }
        return nil
    }

    private static func locationID(from value: Any) -> Int? {
        if let value = value as? Int { return value }
        if let number = value as? NSNumber { return number.intValue }
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"0x[0-9a-fA-F]+"#,
                                     options: .regularExpression) {
            return Int(trimmed[range].dropFirst(2), radix: 16)
        }
        let digits = trimmed.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    private static func findSpeed(in device: [String: Any]) -> Int? {
        // system_profiler commonly reports strings such as "Up to 480 Mb/s"
        // or "Up to 5 Gb/s". Search speed-looking fields first.
        let ordered = device.sorted { lhs, rhs in
            let l = lhs.key.lowercased()
            let r = rhs.key.lowercased()
            let lScore = (l.contains("usb") ? 2 : 0) + (l.contains("link") ? 2 : 0) + (l.contains("speed") ? 1 : 0)
            let rScore = (r.contains("usb") ? 2 : 0) + (r.contains("link") ? 2 : 0) + (r.contains("speed") ? 1 : 0)
            return lScore > rScore
        }
        for (key, raw) in ordered where key.lowercased().contains("speed") {
            if let string = raw as? String, let mbps = parseSpeedString(string) { return mbps }
        }
        // Some macOS versions nest details one level deeper.
        for raw in device.values {
            if let dict = raw as? [String: Any], let mbps = findSpeed(in: dict) { return mbps }
        }
        return nil
    }

    static func parseSpeedString(_ value: String) -> Int? {
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*([GMK])(?:b|bit)?/?s"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: normalized,
                                           range: NSRange(normalized.startIndex..., in: normalized)),
              let numberRange = Range(match.range(at: 1), in: normalized),
              let unitRange = Range(match.range(at: 2), in: normalized),
              let number = Double(normalized[numberRange]) else { return nil }
        let multiplier: Double
        switch normalized[unitRange].uppercased() {
        case "G": multiplier = 1_000
        case "M": multiplier = 1
        case "K": multiplier = 0.001
        default: return nil
        }
        return Int((number * multiplier).rounded())
    }

    static func parseText(profile: String, udid: String, locationID: Int? = nil) -> USBLinkInfo? {
        let wanted = normalizeIdentifier(udid)
        let lines = profile.components(separatedBy: .newlines)
        let serialIndex = !wanted.isEmpty ? lines.firstIndex(where: {
            normalizeIdentifier($0).contains(wanted)
        }) : nil
        let locationIndex = locationID.flatMap { location -> Int? in
            let hex = String(format: "0x%08x", UInt32(truncatingIfNeeded: location))
            return lines.firstIndex(where: {
                $0.localizedCaseInsensitiveContains(hex)
                    || ($0.localizedCaseInsensitiveContains("location")
                        && locationID(from: $0) == location)
            })
        }
        guard let anchorIndex = serialIndex ?? locationIndex else { return nil }

        // Speed and serial are sibling properties in system_profiler's device
        // block. Search a small symmetric window because their order differs
        // across macOS versions and device classes. Choose the nearest speed.
        let lower = max(0, anchorIndex - 20)
        let upper = min(lines.count - 1, anchorIndex + 20)
        let candidates = (lower...upper).compactMap { index -> (Int, Int)? in
            guard lines[index].localizedCaseInsensitiveContains("speed"),
                  let mbps = parseSpeedString(lines[index]) else { return nil }
            return (abs(index - anchorIndex), mbps)
        }
        guard let nearest = candidates.min(by: { $0.0 < $1.0 }) else { return nil }
        return USBLinkInfo(megabitsPerSecond: nearest.1)
    }

    private static func normalizeIdentifier(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
