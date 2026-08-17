import Foundation

/// Pure identity/routing policy shared by Bonjour/AWDL and usbmux discovery.
/// Kept Network.framework-free so the important merge rules are unit-testable.
enum PeerIdentity {
    /// Bonjour service names are unique within an mDNS domain (collision names
    /// are disambiguated by Bonjour), and stay identical whether the same
    /// service is observed over infrastructure Wi-Fi or AWDL.
    static func bonjourRouteKey(serviceName: String?, installID: String?, fallback: String) -> String {
        if let serviceName, !serviceName.isEmpty {
            return "service:\(serviceName.lowercased())"
        }
        if let installID, !installID.isEmpty { return "id:\(installID)" }
        return "endpoint:\(fallback)"
    }

    /// Match the Bonjour face of a device to its USB face. If both sides have
    /// a stable install ID, an ID mismatch is authoritative: do not fall back
    /// to a possibly duplicated user-visible name. Name matching is only for
    /// old/first-contact peers where one side has no stable ID yet.
    static func matchesUSB(
        bonjourInstallID: String?,
        serviceName: String?,
        usbInstallID: String?,
        usbName: String?
    ) -> Bool {
        if let bonjourInstallID, !bonjourInstallID.isEmpty,
           let usbInstallID, !usbInstallID.isEmpty {
            return bonjourInstallID == usbInstallID
        }
        guard let serviceName, let usbName else { return false }
        return serviceName == usbName
    }

    /// Prefer the route that can be bound to AWDL. TXT identity metadata is
    /// the secondary tie-breaker when duplicate browser results represent the
    /// same Bonjour service.
    static func shouldReplaceRoute(
        currentHasPeerToPeer: Bool,
        currentHasInstallID: Bool,
        candidateHasPeerToPeer: Bool,
        candidateHasInstallID: Bool
    ) -> Bool {
        if candidateHasPeerToPeer != currentHasPeerToPeer {
            return candidateHasPeerToPeer
        }
        return candidateHasInstallID && !currentHasInstallID
    }
}
