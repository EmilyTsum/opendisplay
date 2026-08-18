import XCTest

final class TransportPolicyTests: XCTestCase {
    private func sample(rtt: Double, e2e95: Double = 30, stalls: Int = 0,
                        drops: Int = 0, fps: Double = 120, cap: Double = 120,
                        mbps: Double = 100) -> TransportHealthSample {
        .init(rttMs: rtt, e2e95Ms: e2e95, stalls: stalls, netDrops: drops,
              fps: fps, captureFps: cap, mbps: mbps)
    }

    func testLowRTTAWDLCanBeatUSB() {
        XCTAssertLessThan(sample(rtt: 5, e2e95: 32).score,
                          sample(rtt: 13, e2e95: 45).score)
    }

    func testStallsAndDropsCanOutweighSlightlyBetterRTT() {
        XCTAssertGreaterThan(sample(rtt: 4, e2e95: 40, stalls: 2, drops: 1).score,
                             sample(rtt: 7, e2e95: 32).score)
    }

    func testMbpsDoesNotAffectRouteScore() {
        let a = sample(rtt: 7, mbps: 20)
        let b = sample(rtt: 7, mbps: 900)
        XCTAssertEqual(a.score, b.score, accuracy: 0.0001)
    }

    func testHysteresisRejectsSmallDifference() {
        var p = TransportPolicy(initial: .usb, now: 0)
        p.record(sample(rtt: 10), for: .usb, now: 1)
        p.record(sample(rtt: 8), for: .awdl, now: 1)
        XCTAssertFalse(p.shouldSwitch(to: .awdl, now: 30))
    }

    func testHysteresisAcceptsClearDifference() {
        var p = TransportPolicy(initial: .usb, now: 0)
        p.record(sample(rtt: 20, e2e95: 80, stalls: 1), for: .usb, now: 1)
        p.record(sample(rtt: 5, e2e95: 30), for: .awdl, now: 1)
        XCTAssertTrue(p.shouldSwitch(to: .awdl, now: 30))
    }

    func testEWMAOneSpikeDoesNotImmediatelyReverseHealthyRoute() {
        var p = TransportPolicy(initial: .awdl, now: 0)
        for t in 1...8 { p.record(sample(rtt: 5, e2e95: 30), for: .awdl, now: Double(t)) }
        let before = p.estimate(for: .awdl)!.score
        p.record(sample(rtt: 70, e2e95: 180, stalls: 3), for: .awdl, now: 9)
        let after = p.estimate(for: .awdl)!.score
        XCTAssertGreaterThan(after, before)
        XCTAssertLessThan(after, sample(rtt: 70, e2e95: 180, stalls: 3).score)
    }

    func testProbeNeedsTwoWindowsAndRevertsBadCandidate() {
        var p = TransportPolicy(initial: .awdl, now: 0)
        p.record(sample(rtt: 5), for: .awdl, now: 1)
        XCTAssertTrue(p.beginProbe(.usb, now: 25))
        p.record(sample(rtt: 20), for: .usb, now: 26)
        XCTAssertNil(p.probeOutcome(now: 26))
        p.record(sample(rtt: 20), for: .usb, now: 28)
        XCTAssertEqual(p.probeOutcome(now: 28), .revert(.awdl))
    }

    func testProbeKeepsClearlyBetterCandidate() {
        var p = TransportPolicy(initial: .usb, now: 0)
        p.record(sample(rtt: 30, e2e95: 90), for: .usb, now: 1)
        XCTAssertTrue(p.beginProbe(.wifi, now: 25))
        p.record(sample(rtt: 7, e2e95: 30), for: .wifi, now: 26)
        p.record(sample(rtt: 7, e2e95: 30), for: .wifi, now: 28)
        XCTAssertEqual(p.probeOutcome(now: 28), .keep(.wifi))
    }
    func testTransportKindsRemainIndependentRouteIdentities() {
        XCTAssertEqual(Set(TransportKind.allCases).count, 3)
        var p = TransportPolicy(initial: .wifi, now: 0)
        p.record(sample(rtt: 5), for: .awdl, now: 1)
        p.record(sample(rtt: 12), for: .wifi, now: 1)
        p.record(sample(rtt: 20), for: .usb, now: 1)
        XCTAssertNotEqual(p.estimate(for: .awdl)?.score, p.estimate(for: .wifi)?.score)
        XCTAssertNotEqual(p.estimate(for: .wifi)?.score, p.estimate(for: .usb)?.score)
    }

}
