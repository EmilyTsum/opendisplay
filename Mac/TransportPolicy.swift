import Foundation

enum TransportKind: String, CaseIterable, Codable, Hashable, Sendable {
    case usb
    case awdl
    case wifi

    var displayName: String {
        switch self {
        case .usb: return "USB"
        case .awdl: return "AWDL"
        case .wifi: return "WiFi"
        }
    }
}

/// Receiver + sender observations for one short health window. `mbps` is
/// intentionally retained only for diagnostics; it is NOT part of route score
/// because current stream bitrate is not a measure of spare link capacity.
struct TransportHealthSample: Equatable, Sendable {
    var rttMs: Double
    var e2e95Ms: Double
    var stalls: Int
    var netDrops: Int
    var fps: Double
    var captureFps: Double
    var mbps: Double

    var score: Double {
        let tailPenalty = max(e2e95Ms - 25.0, 0) * 0.25
        let stallPenalty = Double(max(stalls, 0)) * 6.0
        let dropPenalty = Double(max(netDrops, 0)) * 8.0
        let fpsDeficit = captureFps > 0 ? max(captureFps - fps, 0) : 0
        return max(rttMs, 0) * 1.2
            + tailPenalty
            + stallPenalty
            + dropPenalty
            + fpsDeficit * 1.5
    }
}

struct TransportEstimate: Equatable {
    var score: Double
    var samples: Int
    var lastUpdatedAt: TimeInterval
}

enum TransportProbeOutcome: Equatable {
    case keep(TransportKind)
    case revert(TransportKind)
}

/// Small, deterministic policy engine. The controller owns one instance per
/// physical receiver and supplies monotonic timestamps so the policy is easy
/// to unit-test without sleeping.
struct TransportPolicy {
    struct Configuration: Equatable {
        var ewmaAlpha = 0.25
        var minimumResidenceSeconds: TimeInterval = 15
        var stableBeforeProbeSeconds: TimeInterval = 20
        var probeCooldownSeconds: TimeInterval = 120
        var probeTimeoutSeconds: TimeInterval = 18
        var minimumProbeSamples = 2
        var minimumRelativeImprovement = 0.15
        var minimumAbsoluteImprovement = 5.0
        var estimateMaxAgeSeconds: TimeInterval = 120
    }

    private struct Probe: Equatable {
        var baseline: TransportKind
        var candidate: TransportKind
        var baselineScore: Double
        var startedAt: TimeInterval
        var candidateSamples = 0
    }

    let configuration: Configuration
    private(set) var current: TransportKind
    private(set) var estimates: [TransportKind: TransportEstimate] = [:]
    private(set) var lastSwitchAt: TimeInterval
    private(set) var lastProbeAt: [TransportKind: TimeInterval] = [:]
    private var probe: Probe?

    init(initial: TransportKind,
         now: TimeInterval = ProcessInfo.processInfo.systemUptime,
         configuration: Configuration = .init()) {
        current = initial
        lastSwitchAt = now
        self.configuration = configuration
    }

    var activeProbeCandidate: TransportKind? { probe?.candidate }
    var activeProbeBaseline: TransportKind? { probe?.baseline }

    mutating func record(_ sample: TransportHealthSample,
                         for kind: TransportKind,
                         now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let raw = sample.score
        if let old = estimates[kind] {
            let alpha = min(max(configuration.ewmaAlpha, 0), 1)
            estimates[kind] = TransportEstimate(
                score: old.score * (1 - alpha) + raw * alpha,
                samples: old.samples + 1,
                lastUpdatedAt: now)
        } else {
            estimates[kind] = TransportEstimate(score: raw, samples: 1, lastUpdatedAt: now)
        }
        if var active = probe, active.candidate == kind {
            active.candidateSamples += 1
            probe = active
        }
    }

    func estimate(for kind: TransportKind) -> TransportEstimate? { estimates[kind] }

    func isMeaningfullyBetter(_ candidate: Double, than baseline: Double) -> Bool {
        let absolute = baseline - candidate
        guard absolute >= configuration.minimumAbsoluteImprovement else { return false }
        guard baseline > 0 else { return candidate < baseline }
        return absolute / baseline >= configuration.minimumRelativeImprovement
    }

    func shouldSwitch(to candidate: TransportKind,
                      now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard candidate != current, probe == nil,
              now - lastSwitchAt >= configuration.minimumResidenceSeconds,
              let baseline = estimates[current],
              let challenger = estimates[candidate],
              now - challenger.lastUpdatedAt <= configuration.estimateMaxAgeSeconds else { return false }
        return isMeaningfullyBetter(challenger.score, than: baseline.score)
    }

    func bestCachedCandidate(available: Set<TransportKind>,
                             now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TransportKind? {
        guard probe == nil else { return nil }
        return available
            .filter { $0 != current && shouldSwitch(to: $0, now: now) }
            .compactMap { kind -> (TransportKind, Double)? in
                guard let score = estimates[kind]?.score else { return nil }
                return (kind, score)
            }
            .min(by: { $0.1 < $1.1 })?.0
    }

    mutating func nextProbeCandidate(available: Set<TransportKind>,
                                     now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TransportKind? {
        guard probe == nil,
              available.count > 1,
              now - lastSwitchAt >= configuration.stableBeforeProbeSeconds,
              estimates[current] != nil else { return nil }

        let candidates = available.filter { $0 != current }
        let eligible = candidates.filter { kind in
            guard let last = lastProbeAt[kind] else { return true }
            return now - last >= configuration.probeCooldownSeconds
        }
        // Prefer never-measured routes, then the stalest measurement. No fixed
        // USB/AWDL/WiFi priority appears here.
        return eligible.min { lhs, rhs in
            switch (estimates[lhs], estimates[rhs]) {
            case (nil, .some): return true
            case (.some, nil): return false
            case (nil, nil): return lhs.rawValue < rhs.rawValue
            case let (.some(l), .some(r)):
                return l.lastUpdatedAt < r.lastUpdatedAt
            }
        }
    }

    mutating func beginProbe(_ candidate: TransportKind,
                             now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard candidate != current, probe == nil,
              let baseline = estimates[current] else { return false }
        probe = Probe(baseline: current, candidate: candidate,
                      baselineScore: baseline.score, startedAt: now)
        lastProbeAt[candidate] = now
        return true
    }

    mutating func probeOutcome(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TransportProbeOutcome? {
        guard let p = probe else { return nil }
        if now - p.startedAt >= configuration.probeTimeoutSeconds {
            probe = nil
            return .revert(p.baseline)
        }
        guard p.candidateSamples >= configuration.minimumProbeSamples,
              let candidate = estimates[p.candidate] else { return nil }
        probe = nil
        return isMeaningfullyBetter(candidate.score, than: p.baselineScore)
            ? .keep(p.candidate)
            : .revert(p.baseline)
    }

    mutating func commitSwitch(to kind: TransportKind,
                               now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        current = kind
        lastSwitchAt = now
        probe = nil
    }

    mutating func cancelProbe() { probe = nil }
}
