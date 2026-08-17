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

    func testParsesHumanReadableProfilerFallback() {
        let text = """
            USB 3.1 Bus:

              iPad:
                Product ID: 0x12ab
                Speed: Up to 5 Gb/s
                Serial Number: 00008110-001234567890001E
        """
        let info = USBLinkInfo.parseText(profile: text,
                                         udid: "00008110-001234567890001E")
        XCTAssertEqual(info?.megabitsPerSecond, 5_000)
        XCTAssertEqual(info?.hudLabel, "USB · 5 Gb/s")
    }

    func testFallsBackToJSONLocationIDWhenSerialDoesNotMatch() {
        let profile: [String: Any] = [
            "SPUSBDataType": [[
                "_items": [[
                    "_name": "iPad",
                    "serial_num": "different-serial-representation",
                    "location_id": "0x00100000 / 1",
                    "speed": "Up to 10 Gb/s",
                ]],
            ]],
        ]
        let info = USBLinkInfo.parse(profile: profile,
                                     udid: "00008110-001234567890001E",
                                     locationID: 0x00100000)
        XCTAssertEqual(info?.megabitsPerSecond, 10_000)
    }

    func testFallsBackToTextLocationIDWhenSerialIsMissing() {
        let text = """
            USB 3.1 Bus:

              iPad:
                Product ID: 0x12ab
                Location ID: 0x00100000 / 1
                Speed: Up to 5 Gb/s
        """
        let info = USBLinkInfo.parseText(profile: text,
                                         udid: "not-present-in-profiler",
                                         locationID: 0x00100000)
        XCTAssertEqual(info?.megabitsPerSecond, 5_000)
    }
    func testParsesIORegistryLinkSpeedByLocationID() {
        let profile: [Any] = [[
            "IORegistryEntryName": "iPad",
            "locationID": NSNumber(value: UInt32(0x00100000)),
            "USB Serial Number": "different-profiler-serial",
            "UsbLinkSpeed": NSNumber(value: UInt64(5_000_000_000)),
            "USBSpeed": NSNumber(value: 3),
        ]]
        let info = USBLinkInfo.parse(profile: profile,
                                     udid: "00008110-001234567890001E",
                                     locationID: 0x00100000)
        XCTAssertEqual(info?.megabitsPerSecond, 5_000)
        XCTAssertEqual(info?.hudLabel, "USB · 5 Gb/s")
    }

    func testIORegistryExactLinkSpeedWinsOverSpeedEnum() {
        let profile: [Any] = [[
            "USB Serial Number": "00008110001234567890001E",
            "locationID": NSNumber(value: UInt32(0x00100000)),
            "UsbLinkSpeed": NSNumber(value: UInt64(10_000_000_000)),
            "USBSpeed": NSNumber(value: 3),
        ]]
        let info = USBLinkInfo.parse(profile: profile,
                                     udid: "00008110-001234567890001E",
                                     locationID: 0x00100000)
        XCTAssertEqual(info?.megabitsPerSecond, 10_000)
    }

    func testLocationIDComparisonUses32BitTopologyValue() {
        let unsigned = UInt32(0xF1200000)
        let signed = Int(Int32(bitPattern: unsigned))
        let profile: [Any] = [[
            "locationID": NSNumber(value: signed),
            "UsbLinkSpeed": NSNumber(value: UInt64(480_000_000)),
        ]]
        let info = USBLinkInfo.parse(profile: profile,
                                     udid: "missing",
                                     locationID: Int(unsigned))
        XCTAssertEqual(info?.megabitsPerSecond, 480)
    }

}
