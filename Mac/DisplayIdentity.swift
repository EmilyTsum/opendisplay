import Foundation

/// Owns the virtual-monitor serial independently of the current transport.
///
/// Generation zero deliberately uses the exact FNV-1a derivation shipped by
/// v1.16.1-custom.1, so upgrading does not create a new virtual monitor for
/// healthy devices. If WindowServer poisons that saved identity and keeps it
/// offline, `rollover` advances a persisted per-device generation and derives
/// a fresh serial. The replacement then remains stable across later launches
/// and across USB/WiFi transports.
enum DisplayIdentity {
    private static let generationKey = "displayIdentityGenerationByDeviceID"

    static func serial(for deviceID: String, defaults: UserDefaults = .standard) -> UInt32 {
        derivedSerial(deviceID: deviceID,
                      generation: generation(for: deviceID, defaults: defaults))
    }

    static func rollover(for deviceID: String, defaults: UserDefaults = .standard) -> UInt32 {
        let next = generation(for: deviceID, defaults: defaults) &+ 1
        var generations = defaults.dictionary(forKey: generationKey) ?? [:]
        generations[deviceID] = Int(next)
        defaults.set(generations, forKey: generationKey)
        return derivedSerial(deviceID: deviceID, generation: next)
    }

    static func derivedSerial(deviceID: String, generation: UInt32) -> UInt32 {
        // Preserve the already-released custom.1 identity exactly.
        let material = generation == 0 ? deviceID : "\(deviceID)#\(generation)"
        var hash: UInt32 = 2_166_136_261
        for byte in material.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash == 0 ? 1 : hash
    }

    private static func generation(for deviceID: String, defaults: UserDefaults) -> UInt32 {
        guard let value = defaults.dictionary(forKey: generationKey)?[deviceID] else { return 0 }
        if let number = value as? NSNumber { return number.uint32Value }
        if let integer = value as? Int { return UInt32(truncatingIfNeeded: integer) }
        return 0
    }
}
