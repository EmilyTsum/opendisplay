import XCTest

final class DisplayIdentityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "DisplayIdentityTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testGenerationZeroPreservesLegacyCustomOneSerial() {
        let id = "test-install-id"
        XCTAssertEqual(DisplayIdentity.serial(for: id, defaults: defaults), legacySerial(id))
    }

    func testRolloverChangesThenPersistsSerial() {
        let id = "poisoned-device"
        let original = DisplayIdentity.serial(for: id, defaults: defaults)
        let replacement = DisplayIdentity.rollover(for: id, defaults: defaults)

        XCTAssertNotEqual(replacement, original)
        XCTAssertEqual(DisplayIdentity.serial(for: id, defaults: defaults), replacement)
    }

    func testDifferentDevicesKeepIndependentGenerations() {
        let a0 = DisplayIdentity.serial(for: "A", defaults: defaults)
        let b0 = DisplayIdentity.serial(for: "B", defaults: defaults)
        let a1 = DisplayIdentity.rollover(for: "A", defaults: defaults)

        XCTAssertNotEqual(a0, a1)
        XCTAssertEqual(DisplayIdentity.serial(for: "B", defaults: defaults), b0)
    }

    private func legacySerial(_ identity: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in identity.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash == 0 ? 1 : hash
    }
}
