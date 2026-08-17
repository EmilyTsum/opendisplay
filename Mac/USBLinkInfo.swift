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
        // IORegistry is the authoritative source for the negotiated USB line
        // rate on current macOS (`UsbLinkSpeed` is exposed in bits/sec). It is
        // also faster and less schema/locale-sensitive than system_profiler.
        // Keep both profiler paths as fallbacks for older OS/device classes.
        if let info = detectIORegistry(udid: udid, locationID: locationID) { return info }
        if let info = detectJSON(udid: udid, locationID: locationID) { return info }
        return detectText(udid: udid, locationID: locationID)
    }

    private static func detectIORegistry(udid: String, locationID: Int?) -> USBLinkInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-p", "IOUSB", "-l", "-w0", "-a"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) else { return nil }
        return parse(profile: root, udid: udid, locationID: locationID)
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
                if let parsed = parseLocationID(from: raw),
                   UInt32(truncatingIfNeeded: parsed) == UInt32(truncatingIfNeeded: wanted) {
                    return dict
                }
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

    private static func parseLocationID(from value: Any) -> Int? {
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
        // Current IOUSB registry nodes expose the negotiated line rate as
        // `UsbLinkSpeed` in bits/sec (for example 12_000_000 or 5_000_000_000).
        // Prefer that exact value over the coarser USB speed enum.
        for (key, raw) in device {
            let compactKey = key.lowercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "_", with: "")
            if compactKey.contains("usblinkspeed") || compactKey == "linkspeed" {
                if let bps = numericValue(raw), bps >= 1_000_000 {
                    return Int((bps / 1_000_000.0).rounded())
                }
                if let string = raw as? String, let mbps = parseSpeedString(string) {
                    return mbps
                }
            }
        }

        // system_profiler commonly reports strings such as "Up to 480 Mb/s"
        // or "Up to 5 Gb/s". Search speed-looking fields next.
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

        // Last-resort mapping for IOUSB's enum when UsbLinkSpeed is absent.
        // 0/1/2/3/4/5 correspond to low/full/high/super/super+/USB4-era
        // classes in the registry. Only use values we can express as a useful
        // nominal line rate; exact UsbLinkSpeed always wins above.
        for (key, raw) in device {
            let compactKey = key.lowercased().replacingOccurrences(of: " ", with: "")
            guard compactKey == "usbspeed" || compactKey == "devicespeed",
                  let value = numericValue(raw).map(Int.init) else { continue }
            switch value {
            case 0: return 2       // nominal 1.5 Mb/s, rounded for HUD
            case 1: return 12
            case 2: return 480
            case 3: return 5_000
            case 4: return 10_000
            case 5: return 20_000
            default: break
            }
        }

        // Some macOS versions nest details one level deeper.
        for raw in device.values {
            if let dict = raw as? [String: Any], let mbps = findSpeed(in: dict) { return mbps }
        }
        return nil
    }

    private static func numericValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let int = value as? Int { return Double(int) }
        if let uint = value as? UInt64 { return Double(uint) }
        if let double = value as? Double { return double }
        if let string = value as? String { return Double(string) }
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
                        && parseLocationID(from: $0) == location)
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
