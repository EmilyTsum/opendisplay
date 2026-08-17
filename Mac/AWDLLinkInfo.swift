import Foundation

struct AWDLLinkInfo: Equatable, Sendable {
    let channel: Int?
    let band: Int?
    let bandwidthMHz: Int?
    let frequencyMHz: Int?
    let txRateMbps: Double?
    let rxRateMbps: Double?
    let maxLinkMbps: Double?
    let mcs: Int?
    let rssi: Int?
    let phyMode: Int?
    let masterChannel: Int?
    let secondaryMasterChannel: Int?
    let channelSequence: String?

    var bandLabel: String? {
        switch band {
        case 1: return "2.4 GHz"
        case 2: return "5 GHz"
        case 3: return "6 GHz"
        default: return nil
        }
    }

    static func frequencyMHz(channel: Int, band: Int) -> Int? {
        guard channel > 0 else { return nil }
        switch band {
        case 1:
            if channel == 14 { return 2484 }
            guard (1...13).contains(channel) else { return nil }
            return 2407 + 5 * channel
        case 2:
            return 5000 + 5 * channel
        case 3:
            // 6 GHz normally follows 5950 + 5*n; channel 2 at 5935 MHz is
            // the standardized special case.
            if channel == 2 { return 5935 }
            return 5950 + 5 * channel
        default:
            return nil
        }
    }

    static func parse(_ raw: [AnyHashable: Any]) -> AWDLLinkInfo? {
        func int(_ key: String) -> Int? {
            (raw[key] as? NSNumber)?.intValue ?? raw[key] as? Int
        }
        func double(_ key: String) -> Double? {
            (raw[key] as? NSNumber)?.doubleValue ?? raw[key] as? Double
        }
        let channel = int("channel")
        let band = int("band")
        let info = AWDLLinkInfo(
            channel: channel,
            band: band,
            bandwidthMHz: int("widthMHz"),
            frequencyMHz: channel.flatMap { c in band.flatMap { Self.frequencyMHz(channel: c, band: $0) } },
            txRateMbps: double("txRateMbps"),
            rxRateMbps: double("rxRateMbps"),
            maxLinkMbps: double("maxLinkMbps"),
            mcs: int("mcs"),
            rssi: int("rssi"),
            phyMode: int("phyMode"),
            masterChannel: int("masterChannel"),
            secondaryMasterChannel: int("secondaryMasterChannel"),
            channelSequence: raw["channelSequence"] as? String
        )
        let hasUsefulValue = info.channel != nil || info.txRateMbps != nil || info.rxRateMbps != nil
            || info.maxLinkMbps != nil || info.rssi != nil
        return hasUsefulValue ? info : nil
    }

    static func detect() async -> AWDLLinkInfo? {
        await Task.detached(priority: .utility) {
            guard let raw = ODCopyAWDLLinkInfo() as? [AnyHashable: Any] else { return nil }
            return parse(raw)
        }.value
    }
}
