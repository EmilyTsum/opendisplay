import XCTest

final class USBLinkInfoTests: XCTestCase {
    func testParsesUSB2SystemProfilerShape() {
        let profile: [String: Any] = [
            "SPUSBDataType": [[
                "_name": "USB 3.1 Bus",
                "_items": [[
                    "_name": "iPad",
                    "serial_num": "00008110-001234567890001E",
                    "speed": "Up to 480 Mb/s",
                ]],
            ]],
        ]
        let info = USBLinkInfo.parse(profile: profile, udid: "00008110-001234567890001E")
        XCTAssertEqual(info?.megabitsPerSecond, 480)
        XCTAssertEqual(info?.hudLabel, "USB 2 · 480 Mb/s")
    }

    func testParsesUSB10GAndIgnoresHyphensInIdentifier() {
        let profile: [String: Any] = [
            "SPUSBDataType": [[
                "_items": [[
                    "serial_number": "00008110001234567890001E",
                    "usb_link_speed": "Up to 10 Gb/s",
                ]],
            ]],
        ]
        let info = USBLinkInfo.parse(profile: profile, udid: "00008110-001234567890001E")
        XCTAssertEqual(info?.megabitsPerSecond, 10_000)
        XCTAssertEqual(info?.hudLabel, "USB · 10 Gb/s")
    }

    func testSpeedParserAcceptsCommonUnits() {
        XCTAssertEqual(USBLinkInfo.parseSpeedString("Up to 5 Gb/s"), 5_000)
        XCTAssertEqual(USBLinkInfo.parseSpeedString("480 Mb/s"), 480)
        XCTAssertEqual(USBLinkInfo.parseSpeedString("12 Mbit/s"), 12)
    }
}
