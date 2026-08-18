import SwiftUI
import Network
import Combine
import Sparkle

/// How the app presents itself. One bundle, switched at runtime via the
/// activation policy — like Raycast/Hammerspoon style background agents.
enum AppPresentation: String, CaseIterable {
    case menuBar, dock, background

    var label: String {
        switch self {
        case .menuBar: return "Menu bar"
        case .dock: return "Dock"
        case .background: return "Background only"
        }
    }
}

@main
struct OpenSidecarMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SenderController.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { controller.presentation == .menuBar },
            set: { _ in }
        )) {
            ContentView(controller: controller, updater: appDelegate.updater)
        } label: {
            Image(systemName: controller.running
                  ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Sparkle's standard updater. `startingUpdater: true` boots the updater
    // immediately so scheduled background checks (SUEnableAutomaticChecks)
    // run; the menu item drives manual "Check for Updates…". Held for the
    // app's lifetime here so every window (menu bar + control window) shares
    // one updater instance.
    let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hand the updater to the control window, which is built outside the
        // SwiftUI App scene (NSHostingView), so it can offer the same button.
        MainWindow.updater = updater
        let presentation = SenderController.shared.presentation
        NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
        if presentation != .menuBar {
            MainWindow.show()
        }
    }

    // Background/Dock modes: opening the app again (Spotlight, Finder, Dock
    // click) brings up the control window — Hammerspoon-style.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        MainWindow.show()
        return false
    }
}

/// The control panel as a regular window, for Dock/background presentation.
@MainActor
enum MainWindow {
    private static var window: NSWindow?
    // Set once at launch by AppDelegate so the control window can share the
    // app's single Sparkle updater.
    static var updater: SPUStandardUpdaterController?

    static func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "OpenDisplay"
            w.contentView = NSHostingView(
                rootView: ContentView(controller: SenderController.shared,
                                      updater: updater))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum ConnectionTarget: Hashable {
    case usb(udid: String?)           // wired via built-in usbmuxd; nil = first device
    case wifi(NWBrowser.Result)       // discovered via Bonjour

    /// Stable identity for sessions and persistence — survives Bonjour
    /// re-discovery (fresh NWBrowser.Result) and USB replugs (new DeviceID).
    var sessionID: String {
        switch self {
        case .usb(let udid): return "usb:\(udid ?? "first")"
        case .wifi(let result):
            if case .service(let name, _, _, _) = result.endpoint { return "wifi:\(name)" }
            return "wifi:unknown"
        }
    }
}

/// One connected (or connecting) device: its target, its sender pipeline,
/// and the per-device status the UI shows. Each session owns a full pipeline
/// — virtual display, capture, encoder, socket — so devices are independent:
/// one disconnecting never stalls the others.
@MainActor
final class DeviceSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let target: ConnectionTarget
    let name: String
    let sender: MacSender

    @Published var status = "Starting…"
    @Published var framesSent = 0
    @Published var mbps = 0.0
    // Receiver's per-install identity (from hello) — the key for recognizing
    // the same physical device across USB and WiFi.
    var deviceID: String?
    // "iPhone" / "iPad" from hello — naming fallback while (or in case)
    // lockdown hasn't resolved the device's real name.
    var deviceKind: String?
    var advertisedName: String?
    // `target` names the identity the session was created for; the live
    // socket can migrate independently. Keep the actual route explicit so
    // AWDL and infrastructure Wi-Fi never collapse into a Boolean "wireless".
    @Published var transportKind: TransportKind
    var routePolicy: TransportPolicy
    var onUSB: Bool { transportKind == .usb }
    // The udid the session is (or was last) cabled through, so a usbmuxd
    // detach can be matched back to this session for failover.
    var usbUDID: String?
    // The Bonjour service name this session was started from or failed over
    // to. Kept because browse results routinely arrive without their TXT
    // record (no install id to match on) and the USB device is detached
    // after a failover — the name is then the only link between the session
    // and its service row.
    var wifiServiceName: String?

    var transportLabel: String { transportKind.displayName }

    init(id: String, target: ConnectionTarget, name: String, sender: MacSender,
         transportKind: TransportKind) {
        self.id = id
        self.target = target
        self.name = name
        self.sender = sender
        self.transportKind = transportKind
        self.routePolicy = TransportPolicy(initial: transportKind)
        if case .usb(let udid) = target { usbUDID = udid }
    }
}

@MainActor
final class SenderController: ObservableObject {
    static let shared = SenderController()

    @Published var presentation = AppPresentation(
        rawValue: UserDefaults.standard.string(forKey: "presentation") ?? "") ?? .menuBar {
        didSet {
            UserDefaults.standard.set(presentation.rawValue, forKey: "presentation")
            NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
            // Never strand the user without UI: leaving menu-bar mode opens
            // the window immediately.
            if presentation != .menuBar { MainWindow.show() }
        }
    }

    @Published var sessions: [DeviceSession] = []
    @Published var discovered: [NWBrowser.Result] = []
    private var rawDiscovered: [NWBrowser.Result] = []
    @Published var usbDevices: [UsbmuxDevice] = []
    // `-host x.x.x.x` / `-port n` bypass usbmuxd with a manual TCP endpoint
    // (debugging escape hatch, e.g. an iproxy or SSH tunnel).
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? "127.0.0.1"
    @Published var port = UserDefaults.standard.string(forKey: "port") ?? "9000"
    // `-mode mirror` / `-mode extend` launch argument also works.
    @Published var mode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .extend
    @Published var quality = StreamQuality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .best {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    @Published var codecPreference = CodecPreference(rawValue: UserDefaults.standard.string(forKey: "codecPreference") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(codecPreference.rawValue, forKey: "codecPreference") }
    }
    @Published var refreshRatePreference = RefreshRatePreference(rawValue: UserDefaults.standard.string(forKey: "refreshRatePreference") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(refreshRatePreference.rawValue, forKey: "refreshRatePreference") }
    }
    @Published var audioEnabled = UserDefaults.standard.object(forKey: "audioEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(audioEnabled, forKey: "audioEnabled") }
    }

    var running: Bool { !sessions.isEmpty }

    private var browser: NWBrowser?
    private var usbWatcher: UsbmuxDeviceWatcher?

    // Connection policy — one session per physical device. USB, AWDL and
    // infrastructure Wi-Fi are route candidates, not a priority list. The
    // active session stays alive while TransportPolicy probes stale/unknown
    // alternatives and migrates only the socket through MacSender. A route
    // failure bypasses hysteresis for immediate failover.
    // `-autostart NO` disables automatic session creation and migration.
    private var usbDisabled = Set(UserDefaults.standard.stringArray(forKey: "usbDisabled") ?? []) {
        didSet { UserDefaults.standard.set(Array(usbDisabled), forKey: "usbDisabled") }
    }
    private var wifiRemembered = Set(UserDefaults.standard.stringArray(forKey: "wifiRemembered") ?? []) {
        didSet { UserDefaults.standard.set(Array(wifiRemembered), forKey: "wifiRemembered") }
    }
    // Install id learned from each USB device's hello, persisted, so the
    // same hardware is recognized across transports even when the user
    // renamed the advertised service. @Published so the device list regroups
    // the moment an identity is learned.
    @Published private var installIDByUDID: [String: String] =
        UserDefaults.standard.dictionary(forKey: "installIDByUDID") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(installIDByUDID, forKey: "installIDByUDID") }
    }
    private let autoConnectEnabled = UserDefaults.standard.object(forKey: "autostart") == nil
        || UserDefaults.standard.bool(forKey: "autostart")

    // Bonjour usually reports devices before usbmuxd does — WiFi reconnects
    // wait out this window so a cabled device is dialed over USB first. The
    // deadline closes the window for good: a remembered WiFi device that
    // appears later was brought near the Mac mid-session, which is a user
    // action to confirm, not auto-grab.
    private var wifiAutoConnectArmed = false
    private let wifiAutoConnectDeadline = Date().addingTimeInterval(12)

    init() {
        startBrowsing()
        usbWatcher = UsbmuxDeviceWatcher { [weak self] devices in
            guard let self else { return }
            let detached = Set(self.usbDevices.map(\.udid)).subtracting(devices.map(\.udid))
            self.usbDevices = devices
            self.failover(detachedUDIDs: detached)
            self.autoConnect()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.wifiAutoConnectArmed = true
            self.autoConnect()
        }
    }

    private func startBrowsing() {
        // TXT records carry the receiver's install id (new receivers).
        let params = NWParameters.tcp
        // Public Network.framework opt-in for Apple peer-to-peer Wi-Fi
        // (AWDL). The same Bonjour service can still be discovered through the
        // infrastructure WLAN, so this is additive and retains normal Wi-Fi as
        // the fallback when no direct interface is available.
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_opensidecar._tcp", domain: nil),
                                using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let rawResults = Array(results)
                self.rawDiscovered = rawResults
                self.discovered = self.preferredBonjourResults(rawResults)
                if self.discovered.count != rawResults.count {
                    Log.info("coalesced \(rawResults.count) Bonjour routes into \(self.discovered.count) device identities")
                }
                for result in results {
                    let names = result.interfaces.map(\.name).joined(separator: ",")
                    if !names.isEmpty {
                        Log.info("Bonjour \(self.serviceName(of: result) ?? "device") interfaces=\(names)")
                    }
                }
                self.endSessionsWhoseServiceVanished()
                self.autoConnect()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// AWDL is intentionally selected by the interface on which Bonjour found
    /// the service, rather than by constructing/link-local-address parsing.
    /// `NWInterface.name` is public API and Network.framework carries the
    /// Bonjour endpoint/interface association for us.
    private func peerToPeerInterface(for result: NWBrowser.Result) -> NWInterface? {
        result.interfaces.first { $0.name.lowercased().hasPrefix("awdl") }
    }

    private func infrastructureWiFiInterface(for result: NWBrowser.Result) -> NWInterface? {
        result.interfaces.first { interface in
            interface.type == .wifi && !interface.name.lowercased().hasPrefix("awdl")
        }
    }

    /// Strip the interface baked into a Bonjour observation. The route itself
    /// is constrained explicitly with NWParameters.requiredInterface so the
    /// same service can be dialed independently over AWDL and en0-style Wi-Fi.
    private func routeEndpoint(for result: NWBrowser.Result) -> NWEndpoint {
        if case .service(let name, let type, let domain, _) = result.endpoint {
            return .service(name: name, type: type, domain: domain, interface: nil)
        }
        return result.endpoint
    }

    /// Coalesce infrastructure Wi-Fi and AWDL observations of the same
    /// Bonjour service into one physical-device row, preferring AWDL when it
    /// is available.
    private func preferredBonjourResults(_ results: [NWBrowser.Result]) -> [NWBrowser.Result] {
        var selected: [String: NWBrowser.Result] = [:]
        for result in results {
            let key = PeerIdentity.bonjourRouteKey(
                serviceName: serviceName(of: result),
                installID: txtID(of: result),
                fallback: String(describing: result.endpoint))
            guard let current = selected[key] else {
                selected[key] = result
                continue
            }
            if PeerIdentity.shouldReplaceRoute(
                currentHasPeerToPeer: peerToPeerInterface(for: current) != nil,
                currentHasInstallID: txtID(of: current) != nil,
                candidateHasPeerToPeer: peerToPeerInterface(for: result) != nil,
                candidateHasInstallID: txtID(of: result) != nil) {
                selected[key] = result
            }
        }
        return selected.values.sorted {
            (serviceName(of: $0) ?? String(describing: $0.endpoint))
                .localizedCaseInsensitiveCompare(
                    serviceName(of: $1) ?? String(describing: $1.endpoint)) == .orderedAscending
        }
    }

    // MARK: - Physical-device identity

    private func serviceName(of result: NWBrowser.Result) -> String? {
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private func txtID(of result: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = result.metadata { return txt["id"] }
        return nil
    }

    /// Same hardware? Strong match: the service's install id equals the id
    /// this USB device announced in a (past or present) hello. Fallback for
    /// old receivers: lockdown device name equals the service name.
    private func sameDevice(_ result: NWBrowser.Result, _ device: UsbmuxDevice) -> Bool {
        PeerIdentity.matchesUSB(
            bonjourInstallID: txtID(of: result),
            serviceName: serviceName(of: result),
            usbInstallID: installIDByUDID[device.udid],
            usbName: device.name)
    }

    /// The session (over either transport) already serving this USB device.
    private func activeSession(coveringUSB device: UsbmuxDevice) -> DeviceSession? {
        if let direct = session(for: "usb:\(device.udid)") { return direct }
        return sessions.first { s in
            guard case .wifi(let result) = s.target else { return false }
            return PeerIdentity.matchesUSB(
                bonjourInstallID: s.deviceID ?? txtID(of: result),
                serviceName: serviceName(of: result),
                usbInstallID: installIDByUDID[device.udid],
                usbName: device.name)
        }
    }

    /// The session (over either transport) already serving this WiFi service.
    private func activeSession(coveringWiFi result: NWBrowser.Result) -> DeviceSession? {
        if let name = serviceName(of: result), let direct = session(for: "wifi:\(name)") {
            return direct
        }
        return sessions.first { s in
            guard case .usb(let udid) = s.target else { return false }
            let usbInstallID = s.deviceID ?? udid.flatMap { installIDByUDID[$0] }
            if let udid, let device = usbDevices.first(where: { $0.udid == udid }) {
                return PeerIdentity.matchesUSB(
                    bonjourInstallID: txtID(of: result),
                    serviceName: serviceName(of: result),
                    usbInstallID: usbInstallID,
                    usbName: device.name)
            }
            return PeerIdentity.matchesUSB(
                bonjourInstallID: txtID(of: result),
                serviceName: serviceName(of: result),
                usbInstallID: usbInstallID,
                usbName: s.wifiServiceName ?? s.name)
        }
    }

    // MARK: - Connection policy

    private func autoConnect() {
        guard autoConnectEnabled else { return }
        dedupeSessions()
        // The -host/-port escape hatch is an explicit choice — dial it like
        // the wired devices (it joins them, not replaces them).
        if UserDefaults.standard.object(forKey: "host") != nil,
           !usbDisabled.contains("usb:first"), session(for: "usb:first") == nil {
            connect(to: .usb(udid: nil))
        }
        for device in usbDevices {
            if let covering = activeSession(coveringUSB: device) {
                // Cable presence only makes USB eligible. Never steal a good
                // AWDL/Wi-Fi stream merely because a cable appeared.
                covering.usbUDID = device.udid
                if let id = covering.deviceID { installIDByUDID[device.udid] = id }
            } else if !usbDisabled.contains("usb:\(device.udid)") {
                connect(to: .usb(udid: device.udid))
            }
        }
        guard wifiAutoConnectArmed, Date() < wifiAutoConnectDeadline else { return }
        for result in discovered {
            let target = ConnectionTarget.wifi(result)
            if wifiRemembered.contains(target.sessionID),
               activeSession(coveringWiFi: result) == nil,
               !cabled(result) {
                connect(to: target)
            }
        }
    }

    /// An attached, auto-connectable USB device is (about to be) dialed over
    /// the cable — its WiFi service must not be grabbed in the launch race.
    private func cabled(_ result: NWBrowser.Result) -> Bool {
        usbDevices.contains {
            sameDevice(result, $0) && !usbDisabled.contains("usb:\($0.udid)")
        }
    }

    /// A manual USB selection stays USB when the cable disappears. The sender
    /// will report/retry that route; the user can choose AWDL or Wi-Fi from the
    /// route Picker instead of the controller silently moving the live stream.
    private func failover(detachedUDIDs: Set<String>) {
        guard !detachedUDIDs.isEmpty else { return }
        for session in sessions where session.transportKind == .usb {
            guard let udid = session.usbUDID, detachedUDIDs.contains(udid) else { continue }
            Log.info("selected USB route detached for \(session.id) — awaiting manual route choice")
        }
    }

    /// A quit receiver app loses its Bonjour advertisement within ~1s, far
    /// faster than WiFi dial timeouts can notice (dials to a withdrawn
    /// service stall rather than getting refused). Report the withdrawal to
    /// each live WiFi session's sender; it only acts if its connection is
    /// already down too, which together proves the app is gone. Debounced
    /// 3s: an mDNS record can drop briefly during a WiFi roam — only a
    /// withdrawal that persists counts. One-shot, guarded re-check, so
    /// overlapping browse events at worst repeat an idempotent call.
    private func endSessionsWhoseServiceVanished() {
        for session in sessions where session.transportKind != .usb {
            guard wifiService(for: session) == nil else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak session] in
                guard let self, let session,
                      self.sessions.contains(where: { $0 === session }),
                      self.wifiService(for: session) == nil else { return }
                session.sender.peerServiceWithdrawn()
            }
        }
    }

    /// The discovered WiFi service belonging to this session's device.
    private func wifiService(for session: DeviceSession) -> NWBrowser.Result? {
        rawDiscovered.first { result in
            if let id = txtID(of: result), let deviceID = session.deviceID {
                return id == deviceID
            }
            let name = serviceName(of: result)
            return name != nil && (name == session.wifiServiceName || name == session.name)
        }
    }

    /// Safety net, not a feature: if identity was learned too late (old
    /// receiver, renamed service) and one physical device ended up with two
    /// sessions, the transports steal the receiver's single connection from
    /// each other forever. First eliminate exact session-ID twins (which can
    /// otherwise become orphan senders), then keep the cable over WiFi.
    private func dedupeSessions() {
        let snapshot = sessions
        var keepByID: [String: DeviceSession] = [:]
        for session in snapshot {
            if let keeper = keepByID[session.id] {
                Log.info("duplicate session \(session.id) — keeping existing \(keeper.transportLabel) pipeline")
                if sessions.contains(where: { $0 === session }) { end(session) }
            } else {
                keepByID[session.id] = session
            }
        }

        // Once hello supplies the install identity, collapse any cross-transport
        // launch race by age/order, never by USB/AWDL/Wi-Fi preference.
        var keepByDevice: [String: DeviceSession] = [:]
        for session in snapshot where sessions.contains(where: { $0 === session }) {
            guard let deviceID = session.deviceID else { continue }
            if let keeper = keepByDevice[deviceID], keeper !== session {
                Log.info("two sessions for one device — keeping existing \(keeper.transportLabel), dropping \(session.transportLabel)")
                end(session)
            } else {
                keepByDevice[deviceID] = session
            }
        }
    }

    /// Human-readable device name for a target (no transport suffix — the
    /// UI shows transports separately).
    func label(for target: ConnectionTarget) -> String {
        switch target {
        case .usb(let udid):
            if let device = usbDevices.first(where: { $0.udid == udid }), let name = device.name {
                return name
            }
            return udid == nil ? "Manual (\(host):\(port))" : "iPhone / iPad"
        case .wifi(let result):
            return serviceName(of: result) ?? "WiFi device"
        }
    }

    func session(for id: String) -> DeviceSession? {
        sessions.first { $0.id == id }
    }

    /// Derive a stable, per-device display serial from the session identity.
    /// FNV-1a over the id string; macOS keys saved display arrangement on
    /// vendor/product/serial, so each device keeps its screen position.
    private static func displaySerial(for id: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    func connect(to target: ConnectionTarget, userInitiated: Bool = false,
                 awaitingWake: Bool = false) {
        let id = target.sessionID
        guard session(for: id) == nil else { return }

        // Never create a second session for the same physical device — the
        // receiver holds one connection, so a twin would steal it. But an
        // explicit user click overrides: e.g. right after unplugging the
        // cable, the dying USB session sits in its 10s reconnect grace and
        // would otherwise swallow the tap on the WiFi row.
        let covering: DeviceSession?
        switch target {
        case .usb(let udid?):
            covering = usbDevices.first(where: { $0.udid == udid })
                .flatMap { activeSession(coveringUSB: $0) }
        case .wifi(let result):
            covering = activeSession(coveringWiFi: result)
        default:
            covering = nil
        }
        if let covering {
            guard userInitiated else { return }
            Log.info("user chose \(id) — taking over from \(covering.id)")
            end(covering)
        }

        // Connecting a device clears its "don't auto-connect" state.
        switch target {
        case .usb: usbDisabled.remove(id)
        case .wifi: wifiRemembered.insert(id)
        }

        let transport: SenderTransport
        switch target {
        case .usb(let udid):
            guard let portNum = UInt16(port) else { return }
            if UserDefaults.standard.object(forKey: "host") != nil, udid == nil {
                // Manual override: dial a plain TCP endpoint instead of usbmuxd.
                transport = .tcp(.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: portNum)!),
                                 requiredInterface: nil)
            } else {
                transport = .usb(udid: udid, port: portNum)
            }
        case .wifi(let result):
            if let awdl = peerToPeerInterface(for: result) {
                transport = .tcp(routeEndpoint(for: result), requiredInterface: awdl)
            } else if let wifi = infrastructureWiFiInterface(for: result) {
                transport = .tcp(routeEndpoint(for: result), requiredInterface: wifi)
            } else {
                transport = .tcp(result.endpoint, requiredInterface: nil)
            }
        }

        let initialTransportKind = transportKind(for: transport)
        let name = label(for: target)
        let sender = MacSender(transport: transport, name: name, mode: mode,
                               quality: quality,
                               codecPreference: codecPreference,
                               refreshRatePreference: refreshRatePreference,
                               audioEnabled: audioEnabled,
                               displaySerial: Self.displaySerial(for: id),
                               awaitingWake: awaitingWake)
        let session = DeviceSession(id: id, target: target, name: name, sender: sender,
                                    transportKind: initialTransportKind)
        if case .wifi(let result) = target {
            session.wifiServiceName = serviceName(of: result)
        }
        sender.onStatus = { [weak session] text in
            session?.status = text
            Log.info("status[\(id)]: \(text)")
        }
        sender.onHello = { [weak self, weak session] info in
            guard let self, let session else { return }
            session.deviceID = info.id
            session.deviceKind = info.device
            session.advertisedName = info.name
            if case .usb(let udid?) = session.target, let installID = info.id {
                self.installIDByUDID[udid] = installID
            }
            self.dedupeSessions()
            // The learned identity may reveal that this WiFi session's device
            // is cabled — take the upgrade opportunity right away.
            self.autoConnect()
        }
        sender.onStats = { [weak session] frames, mbps in
            session?.framesSent = frames
            session?.mbps = mbps
        }
        sender.onTransportHealth = { [weak self, weak session] kind, sample in
            guard let self, let session else { return }
            self.handleTransportHealth(session, kind: kind, sample: sample)
        }
        sender.onTransportFailure = { [weak self, weak session] kind in
            guard let self, let session else { return }
            self.handleTransportFailure(session, failed: kind)
        }
        sender.onDisconnected = { [weak self, weak session] in
            // Device unplugged / left the network and stayed gone: end this
            // session fully (virtual display + capture + indicator). No
            // transport fallback — reconnecting is the user's call.
            guard let self, let session else { return }
            Log.info("device disconnected — session \(session.id) stopped")
            self.end(session)
        }
        sender.onPeerSleeping = { [weak self, weak session] in
            // The device locked. Unlike a plain disconnect this is a
            // known-temporary state announced by the receiver, so ending
            // the session (which frees the cursor from the now-invisible
            // display) is paired with a replacement session that dials
            // patiently until the device wakes and accepts again.
            guard let self, let session else { return }
            let target = session.target
            Log.info("session \(session.id) asleep — display down, waiting for wake")
            self.end(session)
            self.connect(to: target, awaitingWake: true)
        }
        sender.onPeerClosed = { [weak self, weak session] in
            // The receiver app quit — a deliberate goodbye, so no reconnect
            // waits around. Reopening the app is a fresh start handled by
            // the normal discovery/auto-connect paths.
            guard let self, let session else { return }
            Log.info("session \(session.id) closed by the receiver — ending")
            self.end(session)
        }
        sessions.append(session)
        Task {
            do {
                try await sender.start()
            } catch is CancellationError {
                // stopped by the user while waiting — nothing to report
            } catch {
                Log.info("sender failed to start: \(error)")
                // A failed start used to leave partially-created virtual
                // displays/capture resources alive behind a red status row.
                // Tear everything down so privacy indicators and stale display
                // identities cannot accumulate across retries.
                sender.stop()
                session.status = "Failed: \(error.localizedDescription)"
            }
        }
    }

    private func transportKind(for transport: SenderTransport) -> TransportKind {
        switch transport {
        case .usb: return .usb
        case .tcp(_, let interface):
            return interface?.name.lowercased().hasPrefix("awdl") == true ? .awdl : .wifi
        }
    }

    /// All currently reachable physical paths for this one receiver. Bonjour
    /// rows remain coalesced in the UI, but route candidates stay separate.
    private func availableTransports(for session: DeviceSession) -> [TransportKind: SenderTransport] {
        var result: [TransportKind: SenderTransport] = [:]
        if let portNum = UInt16(port) {
            let usb = usbDevices.first { device in
                if session.usbUDID == device.udid { return true }
                if let id = session.deviceID, installIDByUDID[device.udid] == id { return true }
                return device.name == session.advertisedName || device.name == session.name
            }
            if let usb, !usbDisabled.contains("usb:\(usb.udid)") {
                result[.usb] = .usb(udid: usb.udid, port: portNum)
            }
        }

        let routes = rawDiscovered.filter { route in
            if let id = txtID(of: route), let deviceID = session.deviceID { return id == deviceID }
            let name = serviceName(of: route)
            return name != nil && (name == session.wifiServiceName
                || name == session.advertisedName || name == session.name)
        }
        for route in routes {
            let endpoint = routeEndpoint(for: route)
            if result[.awdl] == nil, let awdl = peerToPeerInterface(for: route) {
                result[.awdl] = .tcp(endpoint, requiredInterface: awdl)
            }
            if result[.wifi] == nil, let wifi = infrastructureWiFiInterface(for: route) {
                result[.wifi] = .tcp(endpoint, requiredInterface: wifi)
            }
        }
        return result
    }

    private func switchRoute(_ session: DeviceSession, to kind: TransportKind,
                             reason: String, probing: Bool = false) {
        guard sessions.contains(where: { $0 === session }),
              let transport = availableTransports(for: session)[kind],
              kind != session.transportKind else { return }
        let from = session.transportKind
        Log.info("\(probing ? "route probe" : "route switch") \(from.displayName) -> \(kind.displayName) (\(reason))")
        session.transportKind = kind
        if case .usb(let udid, _) = transport { session.usbUDID = udid }
        if case .tcp(let endpoint, _) = transport,
           case .service(let name, _, _, _) = endpoint { session.wifiServiceName = name }
        if !probing { session.routePolicy.commitSwitch(to: kind) }
        session.sender.switchTransport(to: transport)
    }

    private func handleTransportHealth(_ session: DeviceSession, kind: TransportKind,
                                       sample: TransportHealthSample) {
        guard sessions.contains(where: { $0 === session }), session.transportKind == kind else { return }
        let now = ProcessInfo.processInfo.systemUptime
        session.routePolicy.record(sample, for: kind, now: now)
        let score = session.routePolicy.estimate(for: kind)?.score ?? sample.score
        Log.info(String(format: "ROUTE %@ score=%.1f rtt=%.1f e2e95=%.1f stalls=%d drops=%d fps=%.0f/%.0f",
                        kind.displayName, score, sample.rttMs, sample.e2e95Ms,
                        sample.stalls, sample.netDrops, sample.fps, sample.captureFps))
        // Route health remains visible for diagnostics, but never drives an
        // automatic socket migration. In practice AWDL and infrastructure
        // Wi-Fi can trade a few milliseconds from one stats window to the
        // next; probing them by actually moving the live stream caused visible
        // flapping and, worse, repeatedly tore down the dedicated audio lane.
        // The user explicitly selects USB / AWDL / Wi-Fi in SessionRow.
    }

    private func handleTransportFailure(_ session: DeviceSession, failed: TransportKind) {
        guard sessions.contains(where: { $0 === session }), session.transportKind == failed else { return }
        session.routePolicy.cancelProbe()
        Log.info("selected route \(failed.displayName) failed — retaining manual route selection")
    }

    /// Routes currently observable for this receiver. Keep the active route in
    /// the menu even during a brief discovery dropout so the Picker selection
    /// never jumps on its own.
    func availableRouteKinds(for session: DeviceSession) -> [TransportKind] {
        let reachable = Set(availableTransports(for: session).keys).union([session.transportKind])
        return [.usb, .awdl, .wifi].filter { reachable.contains($0) }
    }

    func selectRoute(_ session: DeviceSession, kind: TransportKind) {
        guard sessions.contains(where: { $0 === session }), kind != session.transportKind else { return }
        guard availableTransports(for: session)[kind] != nil else {
            Log.info("manual route \(kind.displayName) requested but is not currently reachable")
            return
        }
        session.routePolicy.cancelProbe()
        switchRoute(session, to: kind, reason: "user selected")
    }

    /// User-initiated disconnect: also opt the device out of auto-connect.
    func disconnect(_ session: DeviceSession) {
        switch session.target {
        case .usb: usbDisabled.insert(session.id)
        case .wifi: wifiRemembered.remove(session.id)
        }
        // A migrated session is also reachable the other way — opt that side
        // out too, or auto-connect resurrects the device moments later.
        if session.onUSB, let udid = session.usbUDID { usbDisabled.insert("usb:\(udid)") }
        if let name = session.wifiServiceName { wifiRemembered.remove("wifi:\(name)") }
        end(session)
    }

    func disconnectAll() {
        sessions.forEach { disconnect($0) }
    }

    private func end(_ session: DeviceSession) {
        session.sender.stop()
        // Remove the exact object we stopped. Removing by `id` could erase a
        // sibling session from the controller without stopping its MacSender,
        // leaving a zombie pipeline that kept redialing and stealing the
        // receiver connection forever.
        sessions.removeAll { $0 === session }
    }

    /// Mode/quality apply per-pipeline at construction — rebuild every session.
    func restartAll() {
        guard running else { return }
        let targets = sessions.map(\.target)
        sessions.forEach { $0.sender.stop() }
        sessions.removeAll()
        targets.forEach { connect(to: $0) }
        autoConnect()   // a rebuilt WiFi session may deserve its cable back
    }

    // MARK: - Device list (one row per physical device)

    struct DeviceEntry: Identifiable {
        let id: String
        let name: String
        let usbTarget: ConnectionTarget?
        let wifiTarget: ConnectionTarget?

        var transportLabel: String {
            switch (usbTarget != nil, wifiTarget != nil) {
            case (true, true): return "USB · WiFi"
            case (true, false): return "USB"
            case (false, true): return "WiFi"
            default: return ""
            }
        }
        /// Lowest latency first.
        var preferredTarget: ConnectionTarget? { usbTarget ?? wifiTarget }
    }

    var deviceEntries: [DeviceEntry] {
        var entries: [DeviceEntry] = []
        var mergedServices = Set<String>()
        var coveredSessionIDs = Set<String>()

        for device in usbDevices {
            // A discovered WiFi service for the same hardware folds into
            // this row instead of appearing as a second device.
            let twin = discovered.first { sameDevice($0, device) }
            if let twin, let name = serviceName(of: twin) { mergedServices.insert(name) }
            let usbTarget = ConnectionTarget.usb(udid: device.udid)
            coveredSessionIDs.insert(usbTarget.sessionID)
            if let twin { coveredSessionIDs.insert(ConnectionTarget.wifi(twin).sessionID) }
            // A WiFi-identity session migrated onto this cable serves the
            // device even when its service is no longer advertised.
            if let covering = activeSession(coveringUSB: device) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(
                id: "device:\(device.udid)",
                name: activeSession(coveringUSB: device)?.advertisedName
                    ?? twin.flatMap(serviceName)
                    ?? device.name
                    ?? session(for: usbTarget.sessionID)?.deviceKind
                    ?? "iPhone / iPad",
                usbTarget: usbTarget,
                wifiTarget: twin.map { .wifi($0) }))
        }
        if UserDefaults.standard.object(forKey: "host") != nil {
            let target = ConnectionTarget.usb(udid: nil)
            coveredSessionIDs.insert(target.sessionID)
            entries.append(DeviceEntry(id: target.sessionID, name: label(for: target),
                                       usbTarget: target, wifiTarget: nil))
        }
        for result in discovered {
            guard let name = serviceName(of: result), !mergedServices.contains(name)
            else { continue }
            let target = ConnectionTarget.wifi(result)
            coveredSessionIDs.insert(target.sessionID)
            // A USB-identity session that failed over to WiFi serves this
            // service — claim it, or it would dangle as a second row and
            // this one would offer a Connect that steals the receiver.
            if let covering = activeSession(coveringWiFi: result) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(id: "service:\(name)", name: name,
                                       usbTarget: nil, wifiTarget: target))
        }
        // Sessions whose device vanished from discovery (e.g. Bonjour record
        // gone while the stream is still alive) keep a row to disconnect.
        for session in sessions where !coveredSessionIDs.contains(session.id) {
            entries.append(DeviceEntry(id: session.id, name: session.name,
                                       usbTarget: nil, wifiTarget: nil))
        }
        return entries
    }

    func session(for entry: DeviceEntry) -> DeviceSession? {
        if let target = entry.usbTarget {
            if let s = session(for: target.sessionID) { return s }
            if case .usb(let udid?) = target,
               let device = usbDevices.first(where: { $0.udid == udid }),
               let s = activeSession(coveringUSB: device) { return s }
        }
        if let target = entry.wifiTarget {
            if let s = session(for: target.sessionID) { return s }
            // Transport-migrated sessions keep their original identity — a
            // USB-identity session failed over to WiFi still owns this row.
            if case .wifi(let result) = target,
               let s = activeSession(coveringWiFi: result) { return s }
        }
        return session(for: entry.id)   // dangling-session rows
    }
}

/// Polls the permission states the app depends on so the UI can surface
/// exactly what's missing instead of failing silently.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published var screenRecording = false
    @Published var accessibility = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    /// Fire the system permission dialog on demand. macOS only shows each
    /// dialog once per reset — after that the call just (re)registers the
    /// app in System Settings, so the row exists to toggle manually.
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestAccessibility() {
        _ = InputInjector.ensureAccessibilityPermission()
        refresh()
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: SenderController
    @StateObject private var permissions = PermissionMonitor()
    // Optional so the view still compiles/previews without an updater (e.g.
    // if Sparkle ever fails to start); the button just disables itself then.
    let updater: SPUStandardUpdaterController?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenDisplay")
                        .font(.title3.bold())
                    Text("Your iPads and iPhones as extra displays")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.running {
                    Button("Disconnect All") { controller.disconnectAll() }
                        .controlSize(.large)
                }
            }
            .padding(16)

            Divider()

            // Settings
            Form {
                Section("Devices") {
                    if controller.deviceEntries.isEmpty {
                        Text("No devices found — plug one in via USB, or open the OpenDisplay app on a device on this WiFi network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(controller.deviceEntries) { entry in
                        if let session = controller.session(for: entry) {
                            // Title from the entry, not the session: the
                            // session name was snapshotted at connect time,
                            // often before lockdown resolved the real name.
                            SessionRow(title: entry.name, session: session,
                                       controller: controller)
                        } else {
                            HStack(alignment: .firstTextBaseline) {
                                Circle()
                                    .fill(.secondary.opacity(0.5))
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                    Text(entry.transportLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let target = entry.preferredTarget {
                                    Button("Connect") {
                                        controller.connect(to: target, userInitiated: true)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                Picker("Mode", selection: $controller.mode) {
                    Text("Extend").tag(CaptureMode.extend)
                    Text("Mirror").tag(CaptureMode.mirror)
                }
                .pickerStyle(.segmented)
                .onChange(of: controller.mode) { controller.restartAll() }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Quality", selection: $controller.quality) {
                        ForEach(StreamQuality.allCases, id: \.self) { q in
                            Text(q.label).tag(q)
                        }
                    }
                    .onChange(of: controller.quality) { controller.restartAll() }
                    Text(controller.quality.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Codec", selection: $controller.codecPreference) {
                    ForEach(CodecPreference.allCases, id: \.self) { pref in
                        Text(pref.label).tag(pref)
                    }
                }
                .onChange(of: controller.codecPreference) { controller.restartAll() }

                Picker("Refresh rate", selection: $controller.refreshRatePreference) {
                    ForEach(RefreshRatePreference.allCases, id: \.self) { pref in
                        Text(pref.label).tag(pref)
                    }
                }
                .onChange(of: controller.refreshRatePreference) { controller.restartAll() }

                Toggle("Stream audio (PCM 48 kHz stereo)", isOn: $controller.audioEnabled)
                    .onChange(of: controller.audioEnabled) { controller.restartAll() }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Show app in", selection: $controller.presentation) {
                        ForEach(AppPresentation.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    if controller.presentation == .background {
                        Text("No menu bar or Dock icon — streaming keeps running. Open the OpenDisplay app again (Spotlight/Finder) to show this window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Display layout") {
                    Button("Arrange Displays…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                .help("Opens System Settings → Displays, where you can position the extended displays relative to your Mac screen (Arrange…). Each device shows up as its own display, named after the device.")

                Section("Permissions") {
                    permissionRow(
                        "Screen Recording",
                        granted: permissions.screenRecording,
                        help: "Required to capture the display.",
                        anchor: "Privacy_ScreenCapture",
                        request: { permissions.requestScreenRecording() }
                    )
                    permissionRow(
                        "Accessibility",
                        granted: permissions.accessibility,
                        help: "Required for touch input from the device.",
                        anchor: "Privacy_Accessibility",
                        request: { permissions.requestAccessibility() }
                    )
                    // macOS offers no API to query Local Network access, so
                    // infer from discovery results and let the user check.
                    permissionRow(
                        "Local Network",
                        granted: !controller.discovered.isEmpty,
                        uncertain: controller.discovered.isEmpty,
                        help: "Required for WiFi mode. If no device appears in the Devices list, allow OpenDisplay under Privacy & Security → Local Network on this Mac AND on the device — and keep the OpenDisplay app open there.",
                        anchor: "Privacy_LocalNetwork"
                    )
                }
            }
            .formStyle(.grouped)
            // Scrollable + fixed panel height: MenuBarExtra windows mis-measure
            // grouped Forms (clipping on small displays), so size explicitly
            // and let the form scroll when it doesn't fit.

            Divider()

            // Status bar
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.running ? .green : .secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                Text(controller.running
                     ? "\(controller.sessions.count) device\(controller.sessions.count == 1 ? "" : "s") connected"
                     : "Idle")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                // Support affordance: bug reports are much easier to act on
                // with the log attached, and users shouldn't have to be told a
                // filesystem path to find it.
                Button("Logs") { Log.revealInFinder() }
                    .controlSize(.small)
                    .help("Reveal the OpenDisplay log files in Finder")
                if let updater {
                    CheckForUpdatesView(updater: updater)
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 440, height: 540)
    }

    @ViewBuilder
    private func permissionRow(_ title: String, granted: Bool, uncertain: Bool = false,
                               help: String, anchor: String,
                               request: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: uncertain ? "questionmark.circle.fill"
                            : granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(uncertain ? .orange : granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if uncertain || !granted {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if uncertain || !granted {
                if let request {
                    Button("Grant…") { request() }
                        .controlSize(.small)
                        .help("Ask macOS for this permission. If the system dialog was already dismissed once, this registers the app under \(title) in System Settings — flip the toggle there.")
                }
                Button("Open Settings") {
                    PermissionMonitor.openPrivacyPane(anchor)
                }
                .controlSize(.small)
            }
        }
    }
}

/// "Check for Updates…" button wired to Sparkle. Follows Sparkle 2's
/// documented SwiftUI pattern: a small view model publishes the updater's
/// `canCheckForUpdates` so the button disables itself while a check is
/// already running (or the updater isn't ready).
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUStandardUpdaterController) {
        self.updater = updater.updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater.updater)
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .controlSize(.small)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

/// One connected device: live status, throughput, reconnect + disconnect.
struct SessionRow: View {
    let title: String
    @ObservedObject var session: DeviceSession
    let controller: SenderController

    private var statusColor: Color {
        if session.status.hasPrefix("Extending") || session.status.hasPrefix("Mirroring")
            || session.status.hasPrefix("Connected") {
            return .green
        }
        if session.status.hasPrefix("Failed") || session.status.contains("stopped") {
            return .red
        }
        return .orange
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("\(session.transportLabel) · \(session.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if session.mbps > 0 {
                Text("\(String(format: "%.1f", session.mbps)) Mbit/s")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Picker("Route", selection: Binding(
                get: { session.transportKind },
                set: { controller.selectRoute(session, kind: $0) }
            )) {
                ForEach(controller.availableRouteKinds(for: session), id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Choose the physical transport. OpenDisplay will not switch routes automatically.")
            Button {
                session.sender.forceReconnect()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Drop the connection and pair with the device again")
            Button("Disconnect") { controller.disconnect(session) }
                .controlSize(.small)
        }
    }
}
