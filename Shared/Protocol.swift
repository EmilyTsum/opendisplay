// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Keep this Foundation-only so it stays platform-neutral.

import Foundation

/// The wire-protocol contract between the two apps, decoupled from the app's
/// marketing version. See COMPATIBILITY.md.
///
/// Bumped only when the wire changes, not every release, so UI-only releases
/// never trigger a compatibility event. A peer that advertises no version is
/// protocol 1 — that's every install in the field that predates the handshake.
enum WireProtocol {
    /// The protocol version this build speaks.
    static let version = 5

    /// Protocol version that introduced Apple Pencil / proximity wire messages.
    /// Peers below this get pencil input as legacy `touch` events.
    static let pencilWireVersion = 3

    /// Protocol version that introduced media capability negotiation: the
    /// receiver advertises HEVC support, its maximum panel refresh rate, and
    /// its user-configured display name in `hello`.
    static let mediaCapabilitiesVersion = 4

    /// Protocol version that introduced low-latency stereo PCM audio packets.
    static let pcmAudioVersion = 5

    /// Oldest peer protocol version this build still supports. Stays at 1
    /// (support everything) until a deliberate two-phase breaking change
    /// raises it — raising this is what turns "peer too old" into a hard gate.
    static let minSupportedPeer = 1

    /// A peer that advertises no `pv` is defined as protocol 1.
    static let assumedWhenAbsent = 1
}

enum StreamAudioFormat: String, Codable, CaseIterable {
    /// Signed 16-bit little-endian, interleaved stereo, 48 kHz.
    case pcmS16LE48kStereo = "pcmS16LE48k2"
}

/// Control-message `type` strings introduced with the handshake. The pre-
/// existing types (`hello`, `ping`, `pong`, `touch`, …) stay inline for now to
/// keep this change additive and low-risk; unify later if we do a wider pass.
enum StreamCodec: String, Codable, CaseIterable {
    case h264
    case hevc
    case proResLT = "proresLT"
    case proResProxy = "proresProxy"

    var isProRes: Bool {
        self == .proResLT || self == .proResProxy
    }

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .proResLT: return "ProRes 422 LT"
        case .proResProxy: return "ProRes 422 Proxy"
        }
    }
}

enum WireMessage {
    static let welcome = "welcome"                  // Mac -> phone: Mac's pv + min supported
    static let updateRequired = "updateRequired"    // Mac -> phone: peer is below the Mac's floor
    static let sleeping = "sleeping"                // phone -> Mac: device locked, reconnect on wake
    static let closing = "closing"                  // phone -> Mac: app quit, end the session for good
}
