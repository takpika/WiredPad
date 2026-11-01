import SwiftUI
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import Darwin
import Network

@main
struct WiredPadMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(model: delegate.model, wireless: delegate.model.wireless, driver: delegate.driver)
        } label: {
            StatusIcon(model: delegate.model)
        }
        Window("WiredPad", id: "settings") {
            SettingsView(model: delegate.model, driver: delegate.driver)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MacSession()
    let driver = DriverExtensionController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startAutomatically()
    }
}

private struct StatusIcon: View {
    @ObservedObject var model: MacSession

    var body: some View {
        if model.hidError != nil || model.volumeError != nil {
            Image(systemName: "ipad.landscape.badge.exclamationmark")
        } else if model.running {
            Image(systemName: "ipad.landscape.badge.play")
        } else {
            Image(systemName: "ipad.landscape")
        }
    }
}

private struct StatusMenu: View {
    @ObservedObject var model: MacSession
    @ObservedObject var wireless: WirelessDirectory
    @ObservedObject var driver: DriverExtensionController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.running ? "mac.state.connected" :
                (model.connecting ? "mac.state.connecting" : "mac.state.disconnected"))
        if model.running, let summary = model.displaySummary {
            Text(summary)
            Text(model.routeDescription)
        } else if !model.running {
            Text(model.status)
        }
        if model.hidError != nil {
            Label(L10n.tr("mac.error.hid"), systemImage: "exclamationmark.triangle")
        }
        if model.volumeError != nil {
            Label(L10n.tr("mac.error.volume"), systemImage: "exclamationmark.triangle")
        }

        Divider()

        Toggle("mac.menu.use", isOn: Binding(
            get: { model.running || model.connecting },
            set: { $0 ? model.start() : model.stop() }
        ))

        let unpaired = wireless.pairablePads.filter { pad in !model.pairedPads.contains { $0.id == pad.id } }
        if !unpaired.isEmpty {
            Divider()
            Text("mac.menu.nearby")
            ForEach(unpaired) { pad in
                Button(L10n.tr("mac.menu.pair", pad.name)) { model.pair(with: pad) }
            }
        }

        Divider()

        Button("mac.menu.settings") {
            openWindow(id: "settings")
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Button("mac.menu.about") {
            NSApp.orderFrontStandardAboutPanel(nil)
            NSApp.activate()
        }
        Button("mac.menu.quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}


private struct SettingsView: View {
    @ObservedObject var model: MacSession
    @ObservedObject var driver: DriverExtensionController

    var body: some View {
        Form {
            Section {
                Text(model.status)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let hidError = model.hidError { errorRow("mac.error.hid", hidError) }
                if let volumeError = model.volumeError { errorRow("mac.error.volume", volumeError) }
            } header: {
                Text(model.running ? "mac.state.connected" :
                        (model.connecting ? "mac.state.connecting" : "mac.state.disconnected"))
            } footer: {
                if !model.running {
                    Text("mac.permission.note")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if driver.isBundled {
                Section {
                    LabeledContent {
                        Button("mac.driver.activate") { driver.activate() }
                    } label: {
                        Text("mac.driver.title")
                        Text(driver.status)
                    }
                }
            }

            Section {
                if model.pairedPads.isEmpty {
                    Text("mac.pair.none")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.pairedPads) { pad in
                    LabeledContent(pad.name) {
                        Button("mac.pair.forget") { model.forget(pad) }
                    }
                }
            } header: {
                Text("mac.pair.section")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("mac.diagnostics.touches", model.maxReceivedTouches, model.maxSentTouches))
                    Text(L10n.tr("mac.diagnostics.appkit", model.nativeTouchEvents, model.maxNativeTouches))
                    Text(L10n.tr("mac.diagnostics.selftest", model.selfTestStatus))
                    Text(model.macTelemetry)
                    Text(model.ipadTelemetry)
                    if !model.linkDiagnostics.isEmpty { Text(model.linkDiagnostics) }
                    if model.displayID != 0 {
                        Text(L10n.tr("mac.display.id", model.displayID))
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                Toggle("mac.diagnostics.overlay", isOn: Binding(
                    get: { model.showDiagnostics },
                    set: { if $0 != model.showDiagnostics { model.toggleDiagnostics() } }
                ))
                if model.displayID != 0 {
                    HStack {
                        Button("mac.diagnostics.probe") { model.openTouchProbe() }
                        Button("mac.diagnostics.hidtest") { model.sendTestTouches() }
                        Button("mac.diagnostics.handover") { model.testHandover() }
                            .disabled(!(model.route.usb && model.route.wifi))
                    }
                }
            } header: {
                Text("mac.diagnostics.title")
            } footer: {
                Text("mac.footer")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func errorRow(_ key: String, _ detail: String) -> some View {
        LabeledContent {
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Label(L10n.tr(key), systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
    }
}

final class MacSession: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published var status = L10n.tr("mac.status.idle")
    @Published var running = false
    @Published private(set) var connecting = false
    @Published var displayID: UInt32 = 0
    @Published var maxReceivedTouches = 0
    @Published var maxSentTouches = 0
    @Published var nativeTouchEvents = 0
    @Published var maxNativeTouches = 0
    @Published var selfTestStatus = L10n.tr("mac.diagnostics.notrun")
    @Published var hidError: String?
    @Published var volumeError: String?
    @Published var macTelemetry = L10n.tr("mac.telemetry.waiting")
    @Published var ipadTelemetry = L10n.tr("ipad.telemetry.waiting")
    @Published var showDiagnostics = false
    @Published private(set) var displaySummary: String?
    @Published private(set) var route = WireSession.LinkStatus()
    @Published private(set) var linkDiagnostics = ""
    @Published private(set) var pairedPads: [PairingStore.Peer] = []

    let wireless = WirelessDirectory()
    private let networkHints = NetworkHintWatcher()
    /// The iPad said over Bluetooth that it is not on a Wi-Fi network.
    private var iPadOffNetwork = false
    /// Where the iPad said it listens on its Wi-Fi network.
    private var hintedEndpoint: NWEndpoint?
    private let interfaces = LocalInterfaces()
    private let pairing = PairingStore()
    private var pairingClient: PairingClient?
    private let sessionQueue = DispatchQueue(label: "WiredPad.session", qos: .userInteractive)
    private let linkQueue = DispatchQueue(label: "WiredPad.links", qos: .userInteractive)
    private var session: WireSession?
    private var sessionIPadID: String?
    private var pendingSessionID: UUID?
    private var linkMonitor: Timer?
    private var usbAttempting = false
    /// Wi-Fi links being opened, with the path each one asked for.
    private var wifiAttempts: [ObjectIdentifier: NetworkPath?] = [:]
    private var wifiAttempting: Bool { !wifiAttempts.isEmpty }
    private var nextWiFiAttempt = 0.0
    /// Wi-Fi attempts alternate: a network path first, then peer-to-peer if that fails.
    /// The link in use, followed by the links standing by.
    var routeDescription: String {
        func name(_ rank: Int) -> String {
            NetworkPath(rank: rank).map { L10n.tr("mac.path.\(String(describing: $0))") } ?? L10n.tr("mac.route.usb")
        }
        guard let primary = route.primaryRank else { return L10n.tr("mac.route.none") }
        let standby = route.ranks.filter { $0 != primary }.map(name)
        if standby.isEmpty { return name(primary) }
        return L10n.tr("mac.route.standby", name(primary), standby.joined(separator: L10n.tr("mac.route.separator")))
    }
    /// The path the Wi-Fi attempt in progress asked for.
    private var wifiTarget: NetworkPath?
    /// When a path that was not available may be tried again.
    private var pathRetry: [NetworkPath: TimeInterval] = [:]
    /// Measured steadiness per path: the 90th percentile of the slowest responses, in ms.
    private var pathScores: [NetworkPath: (ms: Double, at: TimeInterval)] = [:]
    /// Slowest-response samples by link rank, twice a second.
    private var qualitySamples: [Int: [(time: TimeInterval, ms: Double)]] = [:]
    /// A path being tried next to the current Wi-Fi link, and since when it has been up.
    private var trial: (path: NetworkPath, started: TimeInterval?, onUSB: Bool)?
    private var nextTrial = 0.0
    /// When the iPad last said over Bluetooth that it joined its Wi-Fi network.
    private var joinedNetworkAt: TimeInterval?
    private var nextRescue = 0.0
    private var lastNoLinkLog = 0.0
    /// A path was switched to without a fair measurement; compare again soon.
    private var recheckPending = false
    private var peerToPeerRequested = false
    private var peerToPeerRequestedAt = 0.0
    private var primaryChangedAt = 0.0
    private var cableInterfaces: [NWInterface] = []
    private var linklessSince: TimeInterval?
    private var usbPausedUntil = 0.0
    private var reconnectWanted = false
    private var reconnectScheduled = false
    private var manuallyStopped = false
    private var retrying = false
    private var connectionGeneration = 0
    private var stream: SCStream?
    private var captureFilter: SCContentFilter?
    private var captureConfig: SCStreamConfiguration?
    private var captureRestarting = false
    /// The iPad's full screen, which the virtual display was made to fit.
    private var displayHello: DisplayHello?
    /// The video size now shown, as oriented on the iPad, and the one the iPad last asked for.
    private var displaySize: DisplaySize?
    private var wantedSize: DisplaySize?
    private var resizing = false
    private var displayModeName = "native"
    private var wakeObservers: [NSObjectProtocol] = []
    private let captureQueue = DispatchQueue(label: "WiredPad.capture")
    private var lastRateCheck: TimeInterval = 0
    /// The rank of the link in use, for the rate control. Capture queue only.
    private var ratePrimaryRank: Int?
    private var quickestRoundTrips: [(time: TimeInterval, ms: Double)] = []
    private var lastFrame = 0.0
    private var encoder: HardwareVideoEncoder?
    private let sendLock = NSLock()
    private var sendSession: WireSession?
    private var videoTimer: DispatchSourceTimer?
    private var targetFPS = 30
    private var displayMaximumFPS = 60
    private var captureDrops = 0
    private var healthySeconds = 0
    private var touchDevice: CoreTouchDevice?
    private var volumeDevice: CoreVolumeDevice?
    private var probeWindow: NSWindow?

    func toggleDiagnostics() {
        showDiagnostics.toggle()
        sendDiagnosticsControl()
    }

    private func sendDiagnosticsControl() {
        guard let payload = try? JSONEncoder().encode(DiagnosticsControl(visible: showDiagnostics)) else { return }
        session?.send(.diagnostics, payload)
    }

    private var queuedBytes: Int {
        sendLock.lock(); defer { sendLock.unlock() }
        return sendSession?.unackedBytes ?? 0
    }



    func sendTestTouches() {
        guard let touchDevice else { return }
        Task { @MainActor in
            let points = (0..<10).map { index in
                TouchPoint(id: index,
                           x: 0.15 + Double(index % 5) * 0.16,
                           y: 0.35 + Double(index / 5) * 0.3,
                           down: true)
            }
            do {
                try await touchDevice.send(points)
                selfTestStatus = L10n.tr("mac.diagnostics.success")
                try await Task.sleep(nanoseconds: 800_000_000)
                let moved = points.map { TouchPoint(id: $0.id, x: $0.x + 0.02, y: $0.y, down: true) }
                try await touchDevice.send(moved)
                try await Task.sleep(nanoseconds: 800_000_000)
                try await touchDevice.send([])
            } catch {
                selfTestStatus = L10n.tr("mac.diagnostics.failure")
                hidError = error.localizedDescription
            }
        }
    }


    func openTouchProbe() {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return }
        if let probeWindow {
            probeWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: screen.frame.insetBy(dx: 60, dy: 60),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L10n.tr("mac.probe.title")
        // This object keeps the window; AppKit must not release it again when it closes.
        window.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { [weak self] _ in self?.probeWindow = nil }
        let view = NSView(frame: window.contentLayoutRect)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.darkGray.cgColor
        let movingBar = CALayer()
        movingBar.backgroundColor = NSColor.systemCyan.cgColor
        movingBar.cornerRadius = 8
        movingBar.bounds = CGRect(x: 0, y: 0, width: 80, height: 16)
        movingBar.position = CGPoint(x: 60, y: 150)
        let motion = CABasicAnimation(keyPath: "position.x")
        motion.fromValue = 60
        motion.toValue = max(60, view.bounds.width - 60)
        motion.duration = 1
        motion.autoreverses = true
        motion.repeatCount = .infinity
        movingBar.add(motion, forKey: "motion")
        view.layer?.addSublayer(movingBar)
        view.allowedTouchTypes = .direct
        let label = NSTextField(labelWithString: L10n.tr("mac.probe.instruction"))
        label.textColor = .white
        label.font = .systemFont(ofSize: 24)
        label.alignment = .center
        label.frame = CGRect(x: 20, y: 20, width: view.bounds.width - 40, height: 80)
        label.autoresizingMask = [.width, .maxYMargin]
        view.addSubview(label)
        let recognizer = TouchProbeRecognizer { [weak self] count in
            guard let self else { return }
            self.nativeTouchEvents += 1
            self.maxNativeTouches = max(self.maxNativeTouches, count)
        }
        view.addGestureRecognizer(recognizer)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        probeWindow = window
    }

    func startAutomatically() {
        if !manuallyStopped { start() }
    }

    func start() {
        guard !running, !connecting else { return }
        manuallyStopped = false
        reconnectWanted = true
        connectionGeneration += 1
        let generation = connectionGeneration
        connecting = true
        pendingSessionID = UUID()
        wireless.start()
        networkHints.onHint = { [weak self] state in self?.networkHint(state) }
        networkHints.start()
        refreshPairedPads()
        if !retrying { status = L10n.tr("mac.status.searching") }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fd = WiredPadConnectUSB(Wire.port)
            DispatchQueue.main.async {
                guard let self else { if fd >= 0 { close(fd) }; return }
                guard self.connectionGeneration == generation, !self.manuallyStopped else {
                    if fd >= 0 { close(fd) }
                    return
                }
                if fd >= 0 {
                    self.open(USBLink(fd: fd), generation: generation)
                } else if let pad = self.reachablePairedPad(), let link = self.wifiLink(to: pad, path: nil) {
                    self.wifiAttempts[ObjectIdentifier(link)] = .some(nil)
                    self.open(link, generation: generation)
                } else {
                    self.connecting = false
                    self.retrying = true
                    self.status = L10n.tr(String(cString: WiredPadUSBError()))
                    // No cable and no iPad on the network: look over AWDL as well.
                    self.wireless.peerToPeer = true
                    self.scheduleReconnect()
                }
            }
        }
    }

    /// Starts a link's handshake. With no session yet this opens a new one; otherwise the
    /// link joins the running session as another path to the same iPad.
    private func open(_ link: WireLink, generation: Int) {
        guard let sessionID = session?.id ?? pendingSessionID else { link.close(); return }
        let received = session.map { current in sessionQueue.sync { current.receivedSequence } } ?? 0
        let hello = LinkHello(sessionID: sessionID, macID: PairingStore.deviceID,
                              macName: Host.current().localizedName ?? "Mac",
                              kind: link.kind, received: received, resume: session != nil)
        if session == nil { status = L10n.tr("mac.status.negotiating") }
        LinkHandshake.client(link, hello: hello) { [weak self] welcome in
            DispatchQueue.main.async {
                guard let self else { link.close(); return }
                if link.kind == .usb {
                    self.usbAttempting = false
                } else {
                    self.wifiTarget = self.wifiAttempts.removeValue(forKey: ObjectIdentifier(link)) ?? nil
                }
                guard let welcome, self.connectionGeneration == generation, !self.manuallyStopped else {
                    linkLog.info("\(link.kind.rawValue, privacy: .public) handshake failed")
                    link.close()
                    if self.session == nil, self.connectionGeneration == generation, !self.manuallyStopped {
                        self.status = L10n.tr("mac.error.handshake")
                        self.disconnect()
                    }
                    if link.kind == .wifi {
                        let now = ProcessInfo.processInfo.systemUptime
                        self.nextWiFiAttempt = now + 1
                        // An unavailable path waits before it is tried again, so the next one
                        // gets its turn; Wi-Fi LAN comes back soonest.
                        if let target = self.wifiTarget { self.pathRetry[target] = now + (target == .wifiLAN ? 5 : 10) }
                        if self.trial?.started == nil, self.trial != nil {
                            self.trial = nil
                            let onAWDL = self.route.ranks.contains(NetworkPath.peerToPeer.rank)
                            self.nextTrial = now + (onAWDL ? (self.justJoinedNetwork(at: now) ? 2 : 15) : 120)
                        }
                    }
                    return
                }
                self.accept(link, welcome: welcome, generation: generation)
            }
        }
    }

    private func accept(_ link: WireLink, welcome: LinkWelcome, generation: Int) {
        var path: NetworkPath?
        if let network = link as? NetworkLink {
            let local = network.interfaceClass
            // The USB cable carries a network of its own, which goes away with the cable.
            // Leave it out; USB is used directly.
            if local == .wired, let interface = network.interface,
               !LocalInterfaces.networkPorts().contains(interface.name) {
                linkLog.info("skipping the USB cable's network on \(interface.name, privacy: .public)")
                cableInterfaces.append(interface)
                link.close()
                return
            }
            let found = NetworkPath(mac: local, iPad: welcome.interface)
            let now = ProcessInfo.processInfo.systemUptime
            // Asked for one path but got another: the one asked for is not there right now.
            if let target = wifiTarget, target != found { pathRetry[target] = now + 30 }
            // One Wi-Fi link at a time, except a second one on another path while trying it out.
            let networkRanks = route.ranks.filter { $0 > 0 }
            // When the iPad joins its network it drops AWDL, which often comes back before
            // Wi-Fi LAN does; Wi-Fi LAN arriving then is tried at once rather than turned away.
            let joining = found == .wifiLAN && trial == nil && justJoinedNetwork(at: now)
                && networkRanks == [NetworkPath.peerToPeer.rank]
            if session != nil, !networkRanks.isEmpty {
                guard joining || (trial != nil && trial?.started == nil), !networkRanks.contains(found.rank) else {
                    link.close()
                    if trial?.started == nil { trial = nil }
                    return
                }
                trial = (found, now, trial?.onUSB ?? (route.primaryRank == 0))
            } else if trial?.path == found, trial?.started == nil {
                // The path being tried became the only one: nothing left to compare.
                trial = nil
            }
            path = found
            // AWDL slows the network, so check sooner whether Wi-Fi LAN is back.
            if found == .peerToPeer, trial == nil { nextTrial = now + (justJoinedNetwork(at: now) ? 0 : 15) }
            linkLog.info("Wi-Fi link runs over \(String(describing: found), privacy: .public)")
        }
        let rank = path?.rank ?? 0
        if let session {
            guard welcome.iPadID == sessionIPadID, welcome.sessionID == session.id else { link.close(); return }
            guard welcome.resumed else {
                // The iPad no longer has this session, so start over.
                link.close()
                status = L10n.tr("mac.status.reconnecting")
                reconnectWanted = true
                disconnect()
                return
            }
            sessionQueue.async { session.attach(link, peerReceived: welcome.received, rank: rank) }
        } else {
            guard !welcome.resumed, welcome.sessionID == pendingSessionID else { link.close(); return }
            let created = WireSession(id: welcome.sessionID, queue: sessionQueue)
            // Off by default: acknowledgements over USB come back at once, so little is in
            // flight when the cable goes, and an idle Wi-Fi link takes over without a stall.
            // `defaults write <bundle id> WiredPad.standbyFillKbps <n>` turns filler on.
            let fillKbps = UserDefaults.standard.object(forKey: "WiredPad.standbyFillKbps") as? Int ?? 0
            created.standbyFillRate = fillKbps * 1000 / 8
            created.onMessage = { [weak self] type, data in self?.handleMessage(type, data, generation: generation) }
            created.onLinksChanged = { [weak self, weak created] status in
                let details = created.map { L10n.tr("mac.diagnostics.links", $0.handovers, $0.resentPackets,
                                                    $0.duplicatePackets) } ?? ""
                DispatchQueue.main.async { self?.linksChanged(status, details: details) }
            }
            session = created
            sessionIPadID = welcome.iPadID
            sendLock.lock(); sendSession = created; sendLock.unlock()
            sessionQueue.async { created.attach(link, peerReceived: welcome.received, rank: rank) }
            nextTrial = ProcessInfo.processInfo.systemUptime + 20
            wireless.peerToPeer = false
            startLinkMonitor()
        }
        if link.kind == .usb, pairing.key(for: welcome.iPadID) == nil {
            session?.send(.pairingRequest, Data())
        }
    }

    private func linksChanged(_ status: WireSession.LinkStatus, details: String) {
        let wirelessBefore = route.primaryRank.map { $0 > NetworkPath.wiredLAN.rank } ?? false
        if status.primaryRank != route.primaryRank {
            primaryChangedAt = ProcessInfo.processInfo.systemUptime
            let rank = status.primaryRank
            captureQueue.async { [weak self] in
                // A new path has its own quickest round trip.
                self?.ratePrimaryRank = rank
                self?.quickestRoundTrips.removeAll()
            }
            // Wi-Fi carries far less than a cable. Start it at a rate it can take, rather than
            // let the queue grow until the rate control catches up.
            if !wirelessBefore, let rank = status.primaryRank, rank > NetworkPath.wiredLAN.rank {
                captureQueue.async { [weak self] in
                    guard let encoder = self?.encoder else { return }
                    encoder.setBitRate(min(encoder.bitRate, 12_000_000))
                }
            }
        }
        route = status
        linkDiagnostics = details
        if status.usb || status.wifi {
            linklessSince = nil
        } else if linklessSince == nil {
            linklessSince = ProcessInfo.processInfo.systemUptime
            self.status = L10n.tr("mac.status.reconnecting")
        }
    }

    /// While a session runs, keeps a second path ready: USB whenever the cable is in, and
    /// Wi-Fi whenever this iPad is paired and reachable.
    private func startLinkMonitor() {
        linkMonitor?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkLinks()
        }
        // Common modes, so it keeps running while the menu bar menu is open.
        RunLoop.main.add(timer, forMode: .common)
        linkMonitor = timer
    }

    private func checkLinks() {
        guard let session, let iPadID = sessionIPadID else { return }
        let generation = connectionGeneration
        if !route.usb, !usbAttempting, ProcessInfo.processInfo.systemUptime >= usbPausedUntil {
            usbAttempting = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let fd = WiredPadConnectUSB(Wire.port)
                DispatchQueue.main.async {
                    guard let self, fd >= 0, self.session === session else {
                        if fd >= 0 { close(fd) }
                        self?.usbAttempting = false
                        return
                    }
                    self.open(USBLink(fd: fd), generation: generation)
                }
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        sessionQueue.async { [weak self] in
            let delays = session.worstDelays()
            DispatchQueue.main.async { self?.record(delays, at: now) }
        }
        // One Wi-Fi link at a time, on the steadiest path known. While USB carries the session,
        // another path is tried for a few seconds now and then, and the steadier one is kept.
        let networkRanks = route.ranks.filter { $0 > 0 }
        let onUSB = route.primaryRank == 0
        var attempt: NetworkPath?
        /// With no Wi-Fi link at all, every path is tried at once and the first one up is used.
        var parallel: [NetworkPath] = []
        if let current = trial {
            if let started = current.started {
                // A trial run on USB ends early if USB goes away, so the link in use is kept.
                // A network path next to AWDL cannot be measured fairly, so it is moved to as
                // soon as it answers steadily; there is nothing more to learn by waiting.
                let unfair = current.path != .peerToPeer && route.ranks.contains(NetworkPath.peerToPeer.rank)
                    && Self.cleanScore(pathScores[current.path], at: now) == nil
                    && score(rank: current.path.rank, since: started + 2) != nil
                if now - started >= 2, !route.ranks.contains(current.path.rank) {
                    // The path being tried went away, as Wi-Fi LAN may just after the iPad joins
                    // its network: try it again soon rather than judge it.
                    trial = nil
                    nextTrial = now + (justJoinedNetwork(at: now) ? 2 : 15)
                } else if now - started >= 10 || unfair || (current.onUSB && !onUSB) {
                    finishTrial(session: session, at: now)
                }
            } else if !wifiAttempting {
                attempt = current.path
            }
        } else if networkRanks.isEmpty {
            let pending = Set(wifiAttempts.values.compactMap { $0 })
            parallel = Self.macPaths.filter { isAvailable($0, at: now) && !pending.contains($0) }
        } else if networkRanks.count > 1 {
            // Two came up at once: keep the steadier one, or the preferred one before any are
            // measured.
            let attached = networkRanks.compactMap(NetworkPath.init(rank:))
            let keep = attached.min { a, b in
                (pathScores[a]?.ms ?? 200 + Double(Self.macPaths.firstIndex(of: a) ?? 9))
                    < (pathScores[b]?.ms ?? 200 + Double(Self.macPaths.firstIndex(of: b) ?? 9))
            }
            for path in attached where path != keep { sessionQueue.async { session.drop(rank: path.rank) } }
        } else if networkRanks.count == 1, let current = NetworkPath(rank: networkRanks[0]) {
            // Judge a Wi-Fi link in use only once it has settled after taking over. When it gets
            // much worse than it usually is, for example as both devices move away from the
            // router, try the other path: a direct AWDL link may be better by then.
            // The first seconds after connecting or switching are often slow; starting AWDL then
            // would slow the network for a minute and feed the problem.
            let settled = now - primaryChangedAt >= 30
            let usual = pathScores[current]?.ms ?? 100
            let struggling = !onUSB && settled && now >= nextRescue
                && (score(rank: current.rank, since: max(now - 8, primaryChangedAt + 5)) ?? 0) > max(300, usual * 2.5)
            if struggling { nextRescue = now + 30 }
            // Paths are compared now and then, both ways. Without USB, only from AWDL (trying a
            // network path does not disturb the AWDL link), or to re-check a path just switched
            // to without numbers for it.
            let onAWDL = current == .peerToPeer
            if ((onUSB || onAWDL || recheckPending) && now >= nextTrial) || struggling {
                recheckPending = false
                if let solo = score(rank: current.rank, since: now - 10) { pathScores[current] = (solo, now) }
                attempt = Self.macPaths.first { path in
                    path != current && isAvailable(path, at: now)
                        && (struggling || onAWDL || pathScores[path].map { now - $0.at > 600 } ?? true)
                        && !(onAWDL && !struggling && Self.cleanScore(pathScores[path], at: now)
                             .map { $0 >= (pathScores[current]?.ms ?? .infinity) * 0.8 } == true)
                }
                if let attempt { trial = (attempt, nil, onUSB) } else { nextTrial = now + (onAWDL ? 120 : 600) }
            }
        }
        let awdl = NetworkPath.peerToPeer
        let pendingAWDL = wifiAttempts.values.contains(awdl)
        requestPeerToPeer(attempt == awdl || parallel.contains(awdl) || pendingAWDL || trial?.path == awdl
                              || route.ranks.contains(awdl.rank),
                          session: session, at: now)
        let pad = wireless.sessionPads[iPadID] ?? wireless.lastSeenPads[iPadID]
        func connect(_ path: NetworkPath) -> Bool {
            // For Wi-Fi LAN, go straight to the address the iPad gave over Bluetooth.
            let direct = path == .wifiLAN ? hintedEndpoint : nil
            guard let pad, let link = wifiLink(to: pad, path: path, endpoint: direct) else { return false }
            wifiAttempts[ObjectIdentifier(link)] = path
            linkLog.info("connecting \(String(describing: path), privacy: .public) link to \(pad.name, privacy: .public)")
            open(link, generation: generation)
            return true
        }
        // The iPad offers AWDL only while asked, and needs a moment to start offering it.
        // Off its network, the iPad offers AWDL on its own, so there is nothing to wait for.
        let awdlReady = now - peerToPeerRequestedAt >= 1.5 || iPadOffNetwork
        if networkRanks.isEmpty, now - lastNoLinkLog >= 3 {
            lastNoLinkLog = now
            let retry = pathRetry.map { "\($0.key)+\(Int($0.value - now))" }.joined(separator: ",")
            linkLog.info("no Wi-Fi link: trial=\(String(describing: self.trial?.path), privacy: .public) pending=\(self.wifiAttempts.count) retry=\(retry, privacy: .public) pad=\(pad != nil) parallel=\(parallel.map { String(describing: $0) }.joined(separator: ","), privacy: .public)")
        }
        if !parallel.isEmpty, now >= nextWiFiAttempt {
            for path in parallel where path != awdl || awdlReady { _ = connect(path) }
        } else if attempt == awdl, !awdlReady {
            // Wait for the iPad, keeping the trial.
        } else if let attempt, !wifiAttempting, now >= nextWiFiAttempt, connect(attempt) {
        } else if attempt != nil, trial?.started == nil {
            trial = nil
        }
        // Give a lost path time to come back, for example while the iPad joins a network, so
        // the session resumes instead of starting over.
        if let linklessSince, ProcessInfo.processInfo.systemUptime - linklessSince > 30 {
            reconnectWanted = true
            disconnect()
        }
    }

    /// Diagnostics: drops the USB path for five seconds so the move to Wi-Fi and back can be
    /// checked without unplugging the cable.
    func testHandover() {
        guard let session, route.usb, route.wifi else { return }
        usbPausedUntil = ProcessInfo.processInfo.systemUptime + 5
        sessionQueue.async { session.drop(.usb) }
    }

    private func reachablePairedPad() -> WirelessDirectory.NearbyPad? {
        pairing.peers.lazy.compactMap { self.wireless.sessionPads[$0.id] }.first
    }

    /// Paths this Mac can open, in the order they are tried before anything is measured.
    /// Wi-Fi LAN comes before AWDL: once AWDL is up it slows the Wi-Fi network for close to a
    /// minute, so measuring Wi-Fi LAN first keeps that measurement fair. Wi-Fi Aware is not
    /// available on macOS.
    private static let macPaths: [NetworkPath] = [.wiredLAN, .wifiLAN, .peerToPeer]

    private func requestPeerToPeer(_ wanted: Bool, session: WireSession, at now: TimeInterval) {
        guard wanted != peerToPeerRequested else { return }
        peerToPeerRequested = wanted
        peerToPeerRequestedAt = now
        // Look for the iPad over AWDL too, and have it offer AWDL.
        wireless.peerToPeer = wanted
        session.send(.peerToPeer, Data([wanted ? 1 : 0]))
    }

    private func isAvailable(_ path: NetworkPath, at now: TimeInterval) -> Bool {
        (pathRetry[path] ?? 0) <= now && (path != .wiredLAN || interfaces.hasWiredNetwork)
            && (path != .wifiLAN || !iPadOffNetwork)
    }

    /// Acts on the iPad's word that it joined or left its Wi-Fi network, without waiting for a
    /// link to time out or for Bonjour to notice.
    private func networkHint(_ state: NetworkHint.State) {
        guard let session, state.deviceID.uuidString == sessionIPadID else { return }
        hintedEndpoint = state.address.flatMap { address in
            state.port.flatMap(NWEndpoint.Port.init(rawValue:)).map { .hostPort(host: .ipv4(address), port: $0) }
        }
        guard state.onWiFiNetwork == iPadOffNetwork else {
            // The address came in after the iPad joined: try it now if Wi-Fi LAN is not up yet.
            if hintedEndpoint != nil, !route.ranks.contains(NetworkPath.wifiLAN.rank) {
                nextTrial = 0
                checkLinks()
            }
            return
        }
        iPadOffNetwork = !state.onWiFiNetwork
        linkLog.info("iPad \(self.iPadOffNetwork ? "left" : "joined", privacy: .public) its Wi-Fi network (Bluetooth)")
        let lan = NetworkPath.wifiLAN
        if iPadOffNetwork {
            // Its Wi-Fi LAN link cannot carry on; close it now so another path takes over.
            if route.ranks.contains(lan.rank) { sessionQueue.async { session.drop(rank: lan.rank) } }
        } else {
            joinedNetworkAt = ProcessInfo.processInfo.systemUptime
            pathRetry[lan] = nil
            nextWiFiAttempt = 0
            // On AWDL: try Wi-Fi LAN right away, and measure it afresh.
            if route.ranks.contains(NetworkPath.peerToPeer.rank) {
                nextTrial = 0
                pathScores[lan] = nil
            }
        }
        checkLinks()
    }

    private func justJoinedNetwork(at now: TimeInterval) -> Bool {
        !iPadOffNetwork && joinedNetworkAt.map { now - $0 < 30 } == true
    }

    /// The available path with the best measurement; unmeasured paths in their default order.
    private func preferredPath(at now: TimeInterval) -> NetworkPath? {
        let candidates = Self.macPaths.enumerated().filter { isAvailable($0.element, at: now) }
        return candidates.min { a, b in
            func value(_ item: (offset: Int, element: NetworkPath)) -> Double {
                pathScores[item.element].map(\.ms) ?? 200 + Double(item.offset)
            }
            return value(a) < value(b)
        }?.element
    }

    private func record(_ delays: [Int: Double], at now: TimeInterval) {
        for (rank, ms) in delays { qualitySamples[rank, default: []].append((now, ms)) }
        for rank in qualitySamples.keys { qualitySamples[rank]?.removeAll { now - $0.time > 30 } }
    }

    /// How steady a link has been: the 90th percentile of its slowest responses, in ms.
    private func score(rank: Int, since: TimeInterval) -> Double? {
        let values = (qualitySamples[rank] ?? []).filter { $0.time >= since }.map(\.ms).sorted()
        guard values.count >= 4 else { return nil }
        return values[values.count * 9 / 10]
    }

    /// Ends a trial: keeps the steadier of the two Wi-Fi links and closes the other. The new
    /// path has to be clearly better to win, so measurement noise does not cause churn.
    private func finishTrial(session: WireSession, at now: TimeInterval) {
        guard let current = trial, let started = current.started else { return }
        trial = nil
        nextTrial = now + 600
        let others = route.ranks.filter { $0 > 0 && $0 != current.path.rank }
        guard let otherRank = others.first, let other = NetworkPath(rank: otherRank) else { return }
        let measured = score(rank: current.path.rank, since: started + 2)
        // No path is preferred; the steadier one wins. A network path measured while AWDL is
        // in use looks worse than it is, because AWDL slows the network, so for it only a
        // measurement taken without AWDL counts.
        let nextToAWDL = other == .peerToPeer && current.path != .peerToPeer
        let tried = nextToAWDL ? Self.cleanScore(pathScores[current.path], at: now) : measured
        if !nextToAWDL, let measured { pathScores[current.path] = (measured, now) }
        let known = pathScores[other]?.ms ?? score(rank: otherRank, since: started)
        let kept: NetworkPath
        if current.onUSB, route.primaryRank != 0,
           route.primaryRank == current.path.rank || route.primaryRank == other.rank {
            // USB went away during the trial: keep whichever link the session moved to.
            kept = route.primaryRank == current.path.rank ? current.path : other
        } else if nextToAWDL, tried == nil, measured != nil {
            // No fair number for the network path: move to it to measure it without AWDL, and
            // compare again shortly.
            kept = current.path
            recheckPending = true
            nextTrial = now + 60
        } else if let tried, let known {
            kept = tried < known * 0.8 ? current.path : other
        } else {
            // Without numbers for one side, keep the side that has them.
            kept = tried != nil ? current.path : other
        }
        let dropped = kept == other ? current.path : other
        // AWDL slows the network, so a network path is tried again sooner from it.
        if kept == .peerToPeer { nextTrial = now + 120 } else { joinedNetworkAt = nil }
        linkLog.info("path trial: \(String(describing: current.path), privacy: .public) \(tried ?? measured ?? -1, format: .fixed(precision: 0)) ms, \(String(describing: other), privacy: .public) \(self.pathScores[other]?.ms ?? -1, format: .fixed(precision: 0)) ms; keeping \(String(describing: kept), privacy: .public)")
        sessionQueue.async { session.drop(rank: dropped.rank) }
    }

    /// A network path's measurement if it is recent enough to go by. Conditions on the network
    /// change quickly, and while AWDL is in use there is no way to measure it fairly, so an old
    /// number is not trusted: the path is tried again instead.
    private static func cleanScore(_ entry: (ms: Double, at: TimeInterval)?, at now: TimeInterval) -> Double? {
        guard let entry, now - entry.at < 120 else { return nil }
        return entry.ms
    }

    /// A link to the iPad restricted to one path, or to any path when `path` is nil.
    private func wifiLink(to pad: WirelessDirectory.NearbyPad, path: NetworkPath?,
                          endpoint: NWEndpoint? = nil) -> NetworkLink? {
        guard let key = pairing.key(for: pad.id) else { return nil }
        let parameters = SecureTransport.clientParameters(macID: PairingStore.deviceID, key: key)
        parameters.prohibitedInterfaces = cableInterfaces
        switch path {
        case .wiredLAN:
            parameters.includePeerToPeer = false
            parameters.requiredInterfaceType = .wiredEthernet
        case .peerToPeer:
            // AWDL rides on the Wi-Fi radio, so rule out the network interfaces themselves.
            parameters.includePeerToPeer = true
            parameters.prohibitedInterfaceTypes = [.wiredEthernet]
            parameters.prohibitedInterfaces = cableInterfaces + interfaces.network
        case .wifiLAN:
            parameters.includePeerToPeer = false
            parameters.requiredInterfaceType = .wifi
        case .wifiAware, nil:
            break
        }
        let link = NetworkLink(kind: .wifi, connection: NWConnection(to: endpoint ?? pad.endpoint, using: parameters),
                               queue: linkQueue)
        link.closesWhenWaiting = true
        return link
    }

    private func refreshPairedPads() {
        pairedPads = pairing.peers
    }

    func forget(_ pad: PairingStore.Peer) {
        pairing.remove(peerID: pad.id)
        refreshPairedPads()
    }

    /// Pairs with an iPad over Wi-Fi. Both screens show a six-digit code; the person confirms
    /// on each device that they match.
    func pair(with pad: WirelessDirectory.NearbyPad) {
        pairingClient?.cancel()
        let client = PairingClient(endpoint: pad.endpoint, store: pairing)
        client.onCode = { [weak client] code, name in
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = L10n.tr("mac.pair.title", name)
            alert.informativeText = L10n.tr("mac.pair.message", code)
            alert.addButton(withTitle: L10n.tr("mac.pair.confirm"))
            alert.addButton(withTitle: L10n.tr("mac.pair.cancel"))
            if alert.runModal() == .alertFirstButtonReturn { client?.approve() } else { client?.cancel() }
        }
        client.onFinish = { [weak self] outcome in
            guard let self else { return }
            self.pairingClient = nil
            self.refreshPairedPads()
            switch outcome {
            case .paired:
                if !self.running, !self.connecting { self.start() }
            case .failed:
                let alert = NSAlert()
                alert.messageText = L10n.tr("mac.pair.failed")
                alert.runModal()
            case .cancelled:
                break
            }
        }
        pairingClient = client
        client.start()
    }

    private func handleMessage(_ type: UInt8, _ payload: Data, generation: Int) {
        switch type {
        case WireType.hello.rawValue:
            guard let hello = try? JSONDecoder().decode(DisplayHello.self, from: payload),
                  hello.protocolVersion == Wire.version,
                  !hello.hardwareDecoders.isEmpty,
                  (640...4096).contains(hello.width),
                  (480...4096).contains(hello.height),
                  hello.width.isMultiple(of: 2), hello.height.isMultiple(of: 2),
                  (320...2048).contains(hello.logicalWidth),
                  (240...2048).contains(hello.logicalHeight),
                  hello.logicalWidth <= hello.width,
                  hello.logicalHeight <= hello.height,
                  (30...120).contains(hello.maximumFramesPerSecond),
                  (200...400).contains(hello.pixelsPerInch) else {
                DispatchQueue.main.async {
                    guard self.connectionGeneration == generation, !self.manuallyStopped else { return }
                    self.status = L10n.tr("mac.error.displayhello"); self.disconnect()
                }
                return
            }
            DispatchQueue.main.async {
                guard self.connectionGeneration == generation, !self.manuallyStopped, !self.running else { return }
                Task { await self.beginDisplay(hello: hello, generation: generation) }
            }
        case WireType.displaySize.rawValue:
            guard let size = try? JSONDecoder().decode(DisplaySize.self, from: payload),
                  (240...4096).contains(size.width), (240...4096).contains(size.height),
                  size.width.isMultiple(of: 2), size.height.isMultiple(of: 2),
                  (120...2048).contains(size.logicalWidth), (120...2048).contains(size.logicalHeight),
                  size.logicalWidth <= size.width, size.logicalHeight <= size.height else { return }
            DispatchQueue.main.async {
                guard self.connectionGeneration == generation else { return }
                self.wantedSize = size
                Task { await self.applyWantedSize() }
            }
        case WireType.touches.rawValue:
            if let packet = try? JSONDecoder().decode(TouchPacket.self, from: payload) {
                DispatchQueue.main.async { self.applyTouches(packet.points) }
            }
        case WireType.volumeStep.rawValue:
            guard let step = try? JSONDecoder().decode(VolumeStep.self, from: payload),
                  step.direction == 1 || step.direction == -1 else { return }
            DispatchQueue.main.async {
                guard let volumeDevice = self.volumeDevice else {
                    self.volumeError = L10n.tr("mac.error.volumedevice")
                    return
                }
                Task {
                    do {
                        try await volumeDevice.send(step.direction)
                        self.volumeError = nil
                    } catch {
                        self.volumeError = error.localizedDescription
                    }
                }
            }
        case WireType.telemetry.rawValue:
            guard let report = try? JSONDecoder().decode(VideoTelemetry.self, from: payload) else { return }
            updateForIPad(report)
            DispatchQueue.main.async {
                self.ipadTelemetry = L10n.tr("ipad.telemetry.report", report.frames,
                                             report.averageProcessingMS, report.droppedFrames)
            }
        case WireType.pairingKey.rawValue:
            guard let message = try? JSONDecoder().decode(PairingKeyMessage.self, from: payload),
                  message.key.count == 32 else { return }
            DispatchQueue.main.async {
                guard message.iPadID == self.sessionIPadID else { return }
                self.pairing.save(peerID: message.iPadID, name: message.iPadName, key: message.key)
                linkLog.info("paired over USB; key stored: \(self.pairing.key(for: message.iPadID) != nil)")
                self.refreshPairedPads()
            }
        default:
            break
        }
    }

    @MainActor private func beginDisplay(hello: DisplayHello, generation: Int) async {
        guard connectionGeneration == generation, !manuallyStopped else { return }
        let width = hello.width
        let height = hello.height
        let id = WiredPadCreateDisplay(UInt32(width), UInt32(height),
                                       UInt32(hello.logicalWidth), UInt32(hello.logicalHeight),
                                       UInt32(hello.maximumFramesPerSecond), UInt32(hello.pixelsPerInch))
        guard id != 0 else {
            status = L10n.tr(String(cString: WiredPadDisplayError()))
            disconnect()
            return
        }
        displayID = id
        do {
            // A display kept from an earlier session may still have another size.
            _ = WiredPadResizeDisplay(UInt32(width), UInt32(height), UInt32(hello.logicalWidth),
                                      UInt32(hello.logicalHeight), UInt32(hello.maximumFramesPerSecond))
            guard let displayMode = try selectMode(display: id, width: width, height: height,
                                                   logicalWidth: hello.logicalWidth,
                                                   logicalHeight: hello.logicalHeight) else {
                status = L10n.tr("mac.error.mode")
                disconnect()
                return
            }
            var capturedDisplay: SCDisplay?
            for _ in 0..<10 {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                capturedDisplay = content.displays.first(where: { $0.displayID == id })
                if capturedDisplay != nil { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let display = capturedDisplay else {
                status = L10n.tr("mac.error.capture.display")
                disconnect(); return
            }
            guard connectionGeneration == generation, !manuallyStopped else { return }
            touchDevice = CoreTouchDevice(displayID: id)
            if let touchDevice {
                await touchDevice.activate()
            }
            volumeDevice = CoreVolumeDevice()
            if let volumeDevice {
                await volumeDevice.activate()
            }
            guard connectionGeneration == generation, !manuallyStopped else { return }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            var selectedEncoder: HardwareVideoEncoder?
            let candidateRates = Array(Set([hello.maximumFramesPerSecond, 60, 30]
                .filter { $0 <= hello.maximumFramesPerSecond })).sorted(by: >)
            for rate in candidateRates {
                for codec in ["hevc", "h264"] where hello.hardwareDecoders.contains(codec) {
                    if let candidate = try? HardwareVideoEncoder(codec: codec, width: width, height: height,
                                                                 frameRate: rate,
                                                                 onPacket: { [weak self] type, payload in
                        self?.enqueueVideo(type, payload)
                    }) {
                        selectedEncoder = candidate
                        break
                    }
                }
                if selectedEncoder != nil { break }
            }
            guard let selectedEncoder else {
                status = L10n.tr("mac.error.codec")
                disconnect()
                return
            }
            encoder = selectedEncoder
            // Over Wi-Fi, start at a rate it can take; the rate control raises it from there.
            if let rank = route.primaryRank, rank > NetworkPath.wiredLAN.rank {
                selectedEncoder.setBitRate(min(selectedEncoder.bitRate, 12_000_000))
            }
            displayMaximumFPS = selectedEncoder.frameRate
            targetFPS = selectedEncoder.frameRate
            lastFrame = 0
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(selectedEncoder.frameRate))
            config.queueDepth = 3
            config.showsCursor = true
            captureFilter = filter
            captureConfig = config
            let stream = try makeStream(filter: filter, configuration: config)
            self.stream = stream
            try await stream.startCapture()
            watchForWake()
            guard connectionGeneration == generation, !manuallyStopped else {
                try? await stream.stopCapture()
                return
            }
            connecting = false
            reconnectWanted = false
            running = true
            displayHello = hello
            displaySize = DisplaySize(width: width, height: height, logicalWidth: hello.logicalWidth,
                                      logicalHeight: hello.logicalHeight)
            displayModeName = displayMode
            sendDiagnosticsControl()
            let timer = DispatchSource.makeTimerSource(queue: captureQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.sendVideoTelemetry() }
            timer.resume()
            videoTimer = timer
            showDisplayStatus()
            // The iPad may already have asked for another size, such as a portrait one.
            await applyWantedSize()
        } catch {
            guard connectionGeneration == generation, !manuallyStopped else { return }
            status = L10n.tr("mac.error.capture.start", error.localizedDescription)
            disconnect()
        }
    }

    private func showDisplayStatus() {
        guard let hello = displayHello, let size = displaySize, let encoder else { return }
        displaySummary = L10n.tr("mac.menu.summary", size.width, size.height, hello.maximumFramesPerSecond,
                                 encoder.codec.uppercased())
        status = touchDevice != nil
            ? L10n.tr("mac.status.connected", size.width, size.height, size.logicalWidth,
                      size.logicalHeight, hello.pixelsPerInch, hello.maximumFramesPerSecond,
                      displayModeName, encoder.codec.uppercased(), encoder.frameRate)
            : L10n.tr("mac.error.touchdevice")
    }

    /// Picks the display mode with the given pixels, HiDPI if there is one. Returns which
    /// kind it picked, or nil if there was none.
    private func selectMode(display: CGDirectDisplayID, width: Int, height: Int,
                            logicalWidth: Int, logicalHeight: Int) throws -> String? {
        let helper = Process()
        helper.executableURL = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("WiredPadModeHelper")
        helper.arguments = [String(display), String(width), String(height),
                            String(logicalWidth), String(logicalHeight)]
        let output = Pipe()
        helper.standardOutput = output
        try helper.run()
        helper.waitUntilExit()
        guard helper.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "native"
    }

    /// Follows the iPad's video area, after a rotation or a window resize, by giving the
    /// display a mode of that size.
    @MainActor private func applyWantedSize() async {
        guard running, !resizing, let hello = displayHello, let current = displaySize,
              let wanted = wantedSize, wanted != current, let previousEncoder = encoder,
              let stream, let config = captureConfig else { return }
        resizing = true
        defer { resizing = false }
        let generation = connectionGeneration
        guard max(wanted.width, wanted.height) <= hello.width, min(wanted.width, wanted.height) <= hello.height else {
            linkLog.error("display size \(wanted.width)x\(wanted.height) is larger than the iPad screen")
            wantedSize = current
            return
        }
        do {
            guard WiredPadResizeDisplay(UInt32(wanted.width), UInt32(wanted.height), UInt32(wanted.logicalWidth),
                                        UInt32(wanted.logicalHeight), UInt32(hello.maximumFramesPerSecond)),
                  let mode = try selectMode(display: displayID, width: wanted.width, height: wanted.height,
                                            logicalWidth: wanted.logicalWidth, logicalHeight: wanted.logicalHeight)
            else {
                linkLog.error("could not set display mode \(wanted.width)x\(wanted.height)")
                wantedSize = current
                return
            }
            displayModeName = mode
            let encoder = try HardwareVideoEncoder(codec: previousEncoder.codec, width: wanted.width,
                                                   height: wanted.height, frameRate: previousEncoder.frameRate,
                                                   onPacket: { [weak self] type, payload in
                self?.enqueueVideo(type, payload)
            })
            encoder.setBitRate(previousEncoder.bitRate)
            // The display's size changed, so capture it afresh at the new size.
            var captured: SCDisplay?
            for _ in 0..<10 {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                captured = content.displays.first { $0.displayID == displayID && $0.width == wanted.logicalWidth }
                if captured != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard connectionGeneration == generation, running else { return }
            let filter = captured.map { SCContentFilter(display: $0, excludingWindows: []) } ?? captureFilter
            config.width = wanted.width
            config.height = wanted.height
            captureQueue.sync { self.encoder = encoder }
            if let filter {
                captureFilter = filter
                try await stream.updateContentFilter(filter)
            }
            try await stream.updateConfiguration(config)
            displaySize = wanted
            linkLog.info("display is now \(wanted.width)x\(wanted.height)")
            showDisplayStatus()
        } catch {
            linkLog.error("display resize failed: \(error.localizedDescription, privacy: .public)")
            wantedSize = current
            return
        }
        // The iPad may have asked again meanwhile.
        if wantedSize != displaySize {
            resizing = false
            await applyWantedSize()
        }
    }

    private func makeStream(filter: SCContentFilter, configuration: SCStreamConfiguration) throws -> SCStream {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        return stream
    }

    /// ScreenCaptureKit ends the stream on its own when the displays turn off, as they do
    /// while the Mac is locked, and does not start it again. The links stay up meanwhile, so
    /// capture starts again once the displays are back.
    private func watchForWake() {
        guard wakeObservers.isEmpty else { return }
        let restart: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.restartCapture() }
        }
        wakeObservers = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                              object: nil, queue: .main, using: restart),
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                                object: nil, queue: .main, using: restart),
        ]
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        linkLog.info("screen capture stopped: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            // While the displays are off a new stream would stop at once; their wake restarts it.
            if CGDisplayIsAsleep(CGMainDisplayID()) == 0 { self.restartCapture() }
        }
    }

    @MainActor private func restartCapture(attempt: Int = 0) {
        guard running, !captureRestarting, let filter = captureFilter, let config = captureConfig else { return }
        captureRestarting = true
        let generation = connectionGeneration
        let previous = stream
        Task { @MainActor in
            try? await previous?.stopCapture()
            var failure: Error?
            do {
                let restarted = try makeStream(filter: filter, configuration: config)
                try await restarted.startCapture()
                if connectionGeneration == generation, running {
                    stream = restarted
                    linkLog.info("screen capture restarted")
                } else {
                    try? await restarted.stopCapture()
                }
            } catch {
                failure = error
            }
            captureRestarting = false
            guard let failure, connectionGeneration == generation, attempt < 5 else { return }
            linkLog.error("screen capture restart failed: \(failure.localizedDescription, privacy: .public)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            restartCapture(attempt: attempt + 1)
        }
    }

    private func disconnect() {
        if let session {
            sessionQueue.async { session.invalidate() }
        }
        session = nil
        sessionIPadID = nil
        sendLock.lock(); sendSession = nil; sendLock.unlock()
        linkMonitor?.invalidate()
        linkMonitor = nil
        linklessSince = nil
        usbAttempting = false
        wifiAttempts = [:]
        route = WireSession.LinkStatus()
        pathRetry = [:]
        iPadOffNetwork = false
        joinedNetworkAt = nil
        hintedEndpoint = nil
        trial = nil
        peerToPeerRequested = false
        qualitySamples = [:]
        cableInterfaces = []
        wifiTarget = nil
        linkDiagnostics = ""
        if let stream {
            Task { try? await stream.stopCapture() }
            self.stream = nil
        }
        captureFilter = nil
        captureConfig = nil
        displayHello = nil
        displaySize = nil
        wantedSize = nil
        encoder = nil
        videoTimer?.cancel()
        videoTimer = nil
        connecting = false
        running = false
        displaySummary = nil
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectWanted, !reconnectScheduled else { return }
        reconnectScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            if self.reconnectWanted { self.start() }
        }
    }

    func stop() {
        manuallyStopped = true
        reconnectWanted = false
        connectionGeneration += 1
        retrying = false
        disconnect()
        touchDevice = nil
        volumeDevice = nil
        probeWindow?.close()
        probeWindow = nil
        WiredPadDestroyDisplay()
        displayID = 0
        status = L10n.tr("mac.status.stopped")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let encoder else { return }
        let now = Date.timeIntervalSinceReferenceDate
        if targetFPS < displayMaximumFPS,
           now - lastFrame < 1.0 / Double(targetFPS) - 0.002 { return }
        let congested = queuedBytes > 2_000_000
        guard !congested else { captureDrops += 1; return }
        lastFrame = now
        adaptBitRate(now: now)
        do {
            try encoder.encode(sampleBuffer)
        } catch {
            DispatchQueue.main.async { [weak self] in self?.status = error.localizedDescription }
        }
    }

    private func sendVideoTelemetry() {
        guard let encoder else { return }
        let queued = queuedBytes
        var report = encoder.takeTelemetry(queuedBytes: queued)
        report = VideoTelemetry(side: report.side, frames: report.frames,
                                droppedFrames: report.droppedFrames + captureDrops,
                                averageProcessingMS: report.averageProcessingMS,
                                queuedBytes: report.queuedBytes, bitRate: report.bitRate)
        captureDrops = 0
        if let data = try? JSONEncoder().encode(report) { enqueueVideo(.telemetry, data) }
        let currentTarget = targetFPS
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.macTelemetry = L10n.tr("mac.telemetry.report", report.frames, currentTarget,
                                       report.averageProcessingMS, report.queuedBytes / 1024,
                                       report.bitRate / 1_000_000)
        }
    }

    private func updateForIPad(_ report: VideoTelemetry) {
        captureQueue.async { [weak self] in
            guard let self, let encoder = self.encoder else { return }
            let rates = Array(Set([30, 60, 90, 120, self.displayMaximumFPS]
                .filter { $0 <= self.displayMaximumFPS })).sorted()
            let previousRate = self.targetFPS
            if report.droppedFrames > 2 ||
                report.averageProcessingMS > (1000.0 / Double(self.targetFPS)) * 0.75 {
                self.healthySeconds = 0
                self.targetFPS = rates.last(where: { $0 < self.targetFPS }) ?? self.targetFPS
            } else {
                self.healthySeconds += 1
                if self.healthySeconds >= 5 {
                    self.targetFPS = rates.first(where: { $0 > self.targetFPS }) ?? self.targetFPS
                    self.healthySeconds = 0
                }
            }
            if self.targetFPS != previousRate { encoder.setFrameRate(self.targetFPS) }
        }
    }

    /// Keeps the bit rate below what the current path carries without queueing. Data that
    /// waits in a queue shows up as round trips longer than the path's quickest one, so the
    /// rate drops as soon as that wait grows and climbs back slowly while it stays short.
    /// Runs on the capture queue.
    private func adaptBitRate(now: TimeInterval) {
        // AWDL leaves its channel for the Wi-Fi network about once a second, and everything
        // sent meanwhile is acknowledged late at once. Those pauses come whatever the rate, so
        // on AWDL the rate follows the typical wait over two seconds, pauses included.
        let onAWDL = ratePrimaryRank == NetworkPath.peerToPeer.rank
        guard now - lastRateCheck >= (onAWDL ? 2 : 0.25), let encoder else { return }
        lastRateCheck = now
        sendLock.lock(); let current = sendSession; sendLock.unlock()
        guard let current else { return }
        let samples = current.takeRoundTrips().sorted()
        guard !samples.isEmpty else { return }
        // The quickest round trip over the last ten seconds stands for the empty path.
        quickestRoundTrips.append((now, samples[0]))
        quickestRoundTrips.removeAll { now - $0.time > 10 }
        let base = quickestRoundTrips.map(\.ms).min() ?? samples[0]
        // Single long round trips also come from Wi-Fi itself and lowering the rate does not
        // help them, so react to the typical wait and to waits that stay long.
        let typicalWait = samples[samples.count / 2] - base
        if onAWDL {
            if queuedBytes > 1_000_000 || typicalWait > 40 {
                encoder.setBitRate(Int(Double(encoder.bitRate) * 0.85))
            } else if typicalWait < 15 {
                encoder.setBitRate(Int(Double(encoder.bitRate) * 1.08))
            }
            return
        }
        let slowWait = samples[samples.count * 9 / 10] - base
        if queuedBytes > 1_000_000 || typicalWait > 25 || slowWait > 60 {
            encoder.setBitRate(Int(Double(encoder.bitRate) * 0.85))
        } else if slowWait < 20 {
            encoder.setBitRate(Int(Double(encoder.bitRate) * 1.03))
        }
    }

    private func enqueueVideo(_ type: WireType, _ payload: Data) {
        sendLock.lock()
        let current = sendSession
        sendLock.unlock()
        current?.send(type, payload)
    }

    private func applyTouches(_ points: [TouchPoint]) {
        let active = Array(points.filter(\.down).prefix(10))
        maxReceivedTouches = max(maxReceivedTouches, active.count)
        if let touchDevice {
            Task { @MainActor [weak self] in
                do {
                    try await touchDevice.send(active)
                    self?.maxSentTouches = max(self?.maxSentTouches ?? 0, active.count)
                } catch {
                    self?.hidError = error.localizedDescription
                }
            }
        }
    }
}

private final class TouchProbeRecognizer: NSGestureRecognizer {
    private let onTouch: (Int) -> Void
    private var lastLocation = NSPoint.zero

    init(onTouch: @escaping (Int) -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        allowedTouchTypes = .direct
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func location(in view: NSView?) -> NSPoint {
        guard let window = self.view?.window else { return lastLocation }
        return view?.convert(lastLocation, from: nil) ?? window.contentView?.convert(lastLocation, from: nil) ?? lastLocation
    }

    override func touchesBegan(with event: NSEvent) {
        lastLocation = event.locationInWindow
        onTouch(event.touches(matching: .any, in: view).count)
        state = state == .possible ? .began : .changed
    }

    override func touchesMoved(with event: NSEvent) {
        lastLocation = event.locationInWindow
        onTouch(event.touches(matching: .any, in: view).count)
        state = .changed
    }

    override func touchesEnded(with event: NSEvent) {
        state = .ended
    }

    override func touchesCancelled(with event: NSEvent) {
        state = .cancelled
    }
}
