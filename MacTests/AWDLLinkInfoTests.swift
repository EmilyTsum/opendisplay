import XCTest

final class AWDLLinkInfoTests: XCTestCase {
    func testFrequencyMapping() {
        XCTAssertEqual(AWDLLinkInfo.frequencyMHz(channel: 1, band: 1), 2412)
        XCTAssertEqual(AWDLLinkInfo.frequencyMHz(channel: 14, band: 1), 2484)
        XCTAssertEqual(AWDLLinkInfo.frequencyMHz(channel: 149, band: 2), 5745)
        XCTAssertEqual(AWDLLinkInfo.frequencyMHz(channel: 5, band: 3), 5975)
        XCTAssertEqual(AWDLLinkInfo.frequencyMHz(channel: 2, band: 3), 5935)
    }

    func testParsesDriverMetadata() {
        let info = AWDLLinkInfo.parse([
            "channel": 5,
            "band": 3,
            "widthMHz": 160,
            "txRateMbps": 2402.0,
            "rxRateMbps": 2161.0,
            "maxLinkMbps": 2402.0,
            "mcs": 11,
            "rssi": -41,
        ])
        XCTAssertEqual(info?.bandLabel, "6 GHz")
        XCTAssertEqual(info?.frequencyMHz, 5975)
        XCTAssertEqual(info?.bandwidthMHz, 160)
        XCTAssertEqual(info?.txRateMbps, 2402)
        XCTAssertEqual(info?.mcs, 11)
        XCTAssertEqual(info?.rssi, -41)
    }
}
