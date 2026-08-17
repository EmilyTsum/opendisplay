import XCTest

final class PeerIdentityTests: XCTestCase {
    func testWiFiAndAWDLUseSameBonjourIdentity() {
        let wifi = PeerIdentity.bonjourRouteKey(
            serviceName: "Mafu iPad", installID: "install-123", fallback: "en0")
        let awdl = PeerIdentity.bonjourRouteKey(
            serviceName: "Mafu iPad", installID: "install-123", fallback: "awdl0")
        XCTAssertEqual(wifi, awdl)
    }

    func testUSBAndBonjourMatchByInstallIDEvenWhenNamesDiffer() {
        XCTAssertTrue(PeerIdentity.matchesUSB(
            bonjourInstallID: "install-123",
            serviceName: "OpenDisplay iPad",
            usbInstallID: "install-123",
            usbName: "iPad Pro"))
    }

    func testKnownIDMismatchDoesNotFallBackToSameName() {
        XCTAssertFalse(PeerIdentity.matchesUSB(
            bonjourInstallID: "install-A",
            serviceName: "iPad",
            usbInstallID: "install-B",
            usbName: "iPad"))
    }

    func testLegacyPeersCanFallBackToName() {
        XCTAssertTrue(PeerIdentity.matchesUSB(
            bonjourInstallID: nil,
            serviceName: "iPad Pro",
            usbInstallID: nil,
            usbName: "iPad Pro"))
    }

    func testPeerToPeerRouteWinsDuplicateService() {
        XCTAssertTrue(PeerIdentity.shouldReplaceRoute(
            currentHasPeerToPeer: false,
            currentHasInstallID: true,
            candidateHasPeerToPeer: true,
            candidateHasInstallID: true))
        XCTAssertFalse(PeerIdentity.shouldReplaceRoute(
            currentHasPeerToPeer: true,
            currentHasInstallID: true,
            candidateHasPeerToPeer: false,
            candidateHasInstallID: true))
    }
}
