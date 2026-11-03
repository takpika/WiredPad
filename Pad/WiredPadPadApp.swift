import SwiftUI
import UIKit
import Network
import AVFoundation
import CoreMedia
import VideoToolbox
import MediaPlayer
import CryptoKit
import LocalAuthentication
#if canImport(WiFiAware)
import WiFiAware
#endif

@main
struct WiredPadPadApp: App {
    @StateObject private var session = PadSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.black.ignoresSafeArea()
                if session.connected {
                    TouchScreen(session: session) { points in
                        session.sendTouches(points)
                    }
                    .ignoresSafeArea()
                    if session.captureStopped {
                        CaptureStoppedView()
                    }
                    if session.showDiagnostics {
                        VStack {
                            Spacer()
                            Text(session.videoStatus)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(.black.opacity(0.65))
                        }
                        .allowsHitTesting(false)
                    }
                } else {
                    PadWaitingView(session: session)
                }
            }
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .onChange(of: scenePhase) { _, phase in
                session.sceneChanged(phase)
            }
        }
    }
}

/// Covers the last frame while the Mac is not capturing, so it is not taken for a live
/// screen that has stopped responding.
private struct CaptureStoppedView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 54, weight: .light))
                Text(L10n.tr("ipad.capture.stopped.title"))
                    .font(.title2.weight(.semibold))
                Text(L10n.tr("ipad.capture.stopped.detail"))
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(32)
        }
    }
}

private struct PadWaitingView: View {
    @ObservedObject var session: PadSession
    @State private var managingMacs = false

    var body: some View {
        VStack(spacing: 22) {
            if let prompt = session.pairingPrompt {
                pairingCard(prompt)
            } else {
                waiting
            }
        }
        .frame(maxWidth: 480)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if !session.pairedMacs.isEmpty, session.pairingPrompt == nil {
                Button(L10n.tr("ipad.paired.manage", session.pairedMacs.count)) { managingMacs = true }
                    .font(.footnote)
                    .tint(.white.opacity(0.45))
                    .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $managingMacs) {
            PairedMacsView(session: session)
        }
    }

    @ViewBuilder private var waiting: some View {
        Image(systemName: "macbook.and.ipad")
            .font(.system(size: 64, weight: .ultraLight))
            .foregroundStyle(.white.opacity(0.4))
            .symbolEffect(.pulse)
        VStack(spacing: 8) {
            Text(session.status)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Text(verbatim: nativeMode)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    @ViewBuilder private func pairingCard(_ prompt: PadSession.PairingPrompt) -> some View {
        VStack(spacing: 14) {
            Text(L10n.tr("ipad.pair.title", prompt.macName))
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Text(verbatim: prompt.code)
                .font(.system(size: 56, weight: .light, design: .monospaced))
                .foregroundStyle(.white)
            Text("ipad.pair.message")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        HStack(spacing: 12) {
            Button("ipad.pair.deny") { session.answerPairing(false) }
                .buttonStyle(.bordered)
            Button("ipad.pair.allow") { session.answerPairing(true) }
                .buttonStyle(.borderedProminent)
        }
        .tint(.white)
        .controlSize(.large)
    }

    private var nativeMode: String {
        let screen = UIScreen.main
        let size = screen.nativeBounds.size
        let width = Int(max(size.width, size.height))
        let height = Int(min(size.width, size.height))
        return "\(width) × \(height) · \(screen.maximumFramesPerSecond) Hz"
    }
}

private struct PairedMacsView: View {
    @ObservedObject var session: PadSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(session.pairedMacs) { mac in Text(mac.name) }
                        .onDelete { offsets in offsets.map { session.pairedMacs[$0] }.forEach(session.forget) }
                } footer: {
                    Text("ipad.paired.footer")
                }
            }
            .navigationTitle(Text("ipad.paired.title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("ipad.paired.done") { dismiss() }
                }
            }
        }
    }
}

final class PadSession: ObservableObject {
    @Published var status = L10n.tr("ipad.status.waiting")
    @Published var connected = false
    @Published var videoStatus = L10n.tr("ipad.video.waiting")
    @Published var showDiagnostics = false
    /// The Mac stopped capturing its screen, so the picture shown is no longer live.
    @Published var captureStopped = false
    @Published private(set) var pairingPrompt: PairingPrompt?
    @Published private(set) var pairedMacs: [PairingStore.Peer] = []
    private var macVideoStatus = L10n.tr("mac.telemetry.waiting")
    fileprivate weak var canvas: TouchCanvas?
    private lazy var decoder = HardwareVideoDecoder { [weak self] image in
        DispatchQueue.main.async {
            guard let self else { return }
            if self.canvas?.display(image) == true { self.displayedFrames += 1 }
            else { self.droppedFrames += 1 }
        }
    }
    private var decodedFrames = 0
    private var displayedFrames = 0
    private var droppedFrames = 0
    private var totalDecodeMS = 0.0
    private var telemetryTimer: Timer?
    private var volumeObservation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private var originalVolume: Float?
    private var volumeSessionActive = false
    private var volumeBaseline: Float = 0.5
    private var volumeReady = false
    private var brightnessObservation: NSObjectProtocol?
    private var needsFreshConnection = false

    struct PairingPrompt: Equatable {
        let macName: String
        let code: String
    }

    private let queue = DispatchQueue(label: "WiredPad.network", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "WiredPad.session", qos: .userInteractive)
    private let pairing = PairingStore()
    private var usbListener: NWListener?
    private var wifiListener: NWListener?
    private var awareListener: NWListener?
    private var pairListener: NWListener?
    private var listenerRestartScheduled = false
    private var session: WireSession?
    private var sessionMacID: String?
    private var sessionMacName: String?
    private var route = WireSession.LinkStatus()
    private var linklessEnd: DispatchWorkItem?
    private var pairingServer: PairingServer?
    private var pairingFailures: [TimeInterval] = []
    private var pairingPausedUntil: TimeInterval = 0

    private var deviceName: String { UIDevice.current.name }

    init() {
        pairedMacs = pairing.peers
        start()
    }

    /// Offering AWDL keeps it running, which slows the Wi-Fi network. It is offered while this
    /// iPad is not on a Wi-Fi network, when AWDL is the only way to reach it, and in a session
    /// while the Mac asks for it.
    private var macWantsPeerToPeer = false
    private var onWiFiNetwork = true
    private var listenersOfferPeerToPeer = false
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var offersPeerToPeer: Bool { !onWiFiNetwork || (session != nil && macWantsPeerToPeer) }

    private func updatePeerToPeer() {
        guard offersPeerToPeer != listenersOfferPeerToPeer else { return }
        // Links already accepted keep running when the listeners restart.
        restartWiFiListener()
        pairListener?.cancel()
        pairListener = nil
        updatePairingListener()
    }

    /// Tells nearby hosts over Bluetooth when this iPad joins or leaves a Wi-Fi network.
    private lazy var networkHint = UUID(uuidString: PairingStore.deviceID).map { NetworkHintBeacon(deviceID: $0) }

    private func refreshNetworkHint() {
        networkHint?.update(onWiFiNetwork: onWiFiNetwork, port: wifiListener?.port?.rawValue)
    }

    private func start() {
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.onWiFiNetwork = path.status == .satisfied
                self.updatePeerToPeer()
                self.refreshNetworkHint()
            }
        }
        _ = networkHint
        refreshNetworkHint()
        wifiMonitor.start(queue: .main)
        startUSBListener()
        restartWiFiListener()
        updatePairingListener()
    }

    private func stopListeners() {
        for listener in [usbListener, wifiListener, awareListener, pairListener] { listener?.cancel() }
        usbListener = nil
        wifiListener = nil
        awareListener = nil
        pairListener = nil
    }

    /// The USB tunnel arrives through usbmuxd on the loopback interface. Refusing every
    /// other interface keeps this unauthenticated port off the local network.
    private func startUSBListener() {
        guard usbListener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Wire.port)!)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.incoming(NetworkLink(kind: .usb, connection: connection, queue: self.queue))
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    DispatchQueue.main.async {
                        guard let self, self.usbListener === listener else { return }
                        self.status = L10n.tr("ipad.error.listener", error.localizedDescription)
                        self.usbListener = nil
                        listener.cancel()
                        self.scheduleListenerRestart()
                    }
                }
            }
            listener.start(queue: queue)
            usbListener = listener
        } catch {
            status = L10n.tr("ipad.error.listener.start", error.localizedDescription)
            scheduleListenerRestart()
        }
    }

    /// Encrypted Wi-Fi sessions, open only to Macs that hold a pairing key.
    private func restartWiFiListener() {
        wifiListener?.cancel()
        wifiListener = nil
        awareListener?.cancel()
        awareListener = nil
        let keys = pairing.peers.compactMap { peer in pairing.key(for: peer.id).map { (identity: peer.id, key: $0) } }
        guard !keys.isEmpty,
              let listener = try? NWListener(using: SecureTransport.serverParameters(keys: keys,
                                                                                     peerToPeer: offersPeerToPeer))
        else { return }
        listenersOfferPeerToPeer = offersPeerToPeer
        startAwareListener(keys: keys)
        listener.service = NWListener.Service(name: deviceName, type: Wire.sessionService, domain: nil,
                                              txtRecord: advertisement)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.incoming(NetworkLink(kind: .wifi, connection: connection, queue: self.queue))
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { linkLog.error("Wi-Fi listener failed: \(error.localizedDescription, privacy: .public)") }
            if case .ready = state { DispatchQueue.main.async { self?.refreshNetworkHint() } }
        }
        listener.start(queue: queue)
        wifiListener = listener
    }

    /// Wi-Fi Aware is a cross-vendor standard, so hosts other than a Mac can reach this iPad
    /// this way. macOS has no Wi-Fi Aware API, so a Mac never uses it. Hosts still need a
    /// WiredPad pairing key: the link uses the same encrypted transport as Wi-Fi.
    private func startAwareListener(keys: [(identity: String, key: Data)]) {
        #if canImport(WiFiAware)
        guard #available(iOS 26.0, *), WACapabilities.supportedFeatures.contains(.wifiAware),
              let service = WAPublishableService.allServices[Wire.sessionService] else { return }
        let provider = WAPublisherListener.wifiAware(.connecting(to: service, from: .allPairedDevices,
                                                                 datapath: .realtime))
        let parameters = SecureTransport.serverParameters(keys: keys, peerToPeer: false)
        provider.configureParameters(parameters)
        guard let listener = try? NWListener(service: provider.service, using: parameters) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.incoming(NetworkLink(kind: .wifi, connection: connection, queue: self.queue))
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { linkLog.error("Wi-Fi Aware listener failed: \(error.localizedDescription, privacy: .public)") }
        }
        listener.start(queue: queue)
        awareListener = listener
        #endif
    }

    /// Pairing is offered only while the waiting screen shows, one request at a time, and
    /// pauses after repeated declined or failed attempts.
    private func updatePairingListener() {
        let now = ProcessInfo.processInfo.systemUptime
        let wanted = !connected && pairingServer == nil && now >= pairingPausedUntil
        if !wanted {
            pairListener?.cancel()
            pairListener = nil
            if now < pairingPausedUntil {
                DispatchQueue.main.asyncAfter(deadline: .now() + (pairingPausedUntil - now) + 0.1) { [weak self] in
                    self?.updatePairingListener()
                }
            }
            return
        }
        guard pairListener == nil,
              let listener = try? NWListener(using: SecureTransport.pairingParameters(peerToPeer: offersPeerToPeer))
        else { return }
        listener.service = NWListener.Service(name: deviceName, type: Wire.pairingService, domain: nil,
                                              txtRecord: advertisement)
        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async {
                guard let self, self.pairingServer == nil, !self.connected else { connection.cancel(); return }
                self.beginPairing(NetworkLink(kind: .wifi, connection: connection, queue: self.queue))
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { linkLog.error("pairing listener failed: \(error.localizedDescription, privacy: .public)") }
        }
        listener.start(queue: queue)
        pairListener = listener
    }

    private var advertisement: NWTXTRecord {
        NWTXTRecord(["id": PairingStore.deviceID, "name": deviceName])
    }

    private func beginPairing(_ link: NetworkLink) {
        let server = PairingServer(link: link, store: pairing, iPadName: deviceName)
        server.onPrompt = { [weak self] macName, code in
            self?.pairingPrompt = PairingPrompt(macName: macName, code: code)
        }
        server.onFinish = { [weak self] paired in
            guard let self else { return }
            self.pairingServer = nil
            self.pairingPrompt = nil
            if paired {
                self.pairedMacs = self.pairing.peers
                self.restartWiFiListener()
            } else {
                let now = ProcessInfo.processInfo.systemUptime
                self.pairingFailures = self.pairingFailures.filter { now - $0 < 60 } + [now]
                if self.pairingFailures.count >= 3 {
                    self.pairingFailures.removeAll()
                    self.pairingPausedUntil = now + 60
                }
            }
            self.updatePairingListener()
        }
        pairingServer = server
        pairListener?.cancel()
        pairListener = nil
        server.start()
    }

    func answerPairing(_ allow: Bool) {
        pairingServer?.answer(allow)
    }

    func forget(_ mac: PairingStore.Peer) {
        pairing.remove(peerID: mac.id)
        pairedMacs = pairing.peers
        restartWiFiListener()
        if mac.id == sessionMacID, let session {
            // Drop Wi-Fi paths from a removed Mac right away; USB stays trusted.
            sessionQueue.async { if !session.has(.usb) { DispatchQueue.main.async { self.endSession() } } }
        }
    }

    /// This end's view of a link's rank; the Mac ranks its links the same way.
    private static func rank(of link: NetworkLink) -> Int {
        if link.kind == .usb { return 0 }
        switch link.interfaceClass {
        case .wired: return NetworkPath.wiredLAN.rank
        case .peerToPeer: return NetworkPath.peerToPeer.rank
        case .wifiAware: return NetworkPath.wifiAware.rank
        case .wifi, .other: return NetworkPath.wifiLAN.rank
        }
    }

    private func incoming(_ link: NetworkLink) {
        LinkHandshake.server(link) { [weak self] hello in
            DispatchQueue.main.async {
                guard let self, let hello, hello.kind == link.kind else { link.close(); return }
                self.accept(link, hello: hello)
            }
        }
    }

    private func accept(_ link: NetworkLink, hello: LinkHello) {
        if let session, session.id == hello.sessionID, hello.macID == sessionMacID {
            let received = sessionQueue.sync { session.receivedSequence }
            LinkHandshake.welcome(LinkWelcome(sessionID: session.id, iPadID: PairingStore.deviceID,
                                              iPadName: deviceName, received: received, resumed: true,
                                              interface: link.interfaceClass), on: link)
            sessionQueue.async { session.attach(link, peerReceived: hello.received, rank: Self.rank(of: link)) }
            return
        }
        guard !hello.resume else {
            // The Mac is trying to resume a session this iPad no longer has; tell it to start over.
            LinkHandshake.welcome(LinkWelcome(sessionID: hello.sessionID, iPadID: PairingStore.deviceID,
                                              iPadName: deviceName, received: 0, resumed: false), on: link)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { link.close() }
            return
        }
        // Wi-Fi peers already proved a pairing key during the TLS handshake; this also
        // rejects a paired Mac claiming another Mac's identity.
        if link.kind == .wifi, pairing.key(for: hello.macID) == nil { link.close(); return }
        endSession()
        let created = WireSession(id: hello.sessionID, queue: sessionQueue)
        created.onMessage = { [weak self, weak created] type, data in
            guard let created else { return }
            self?.handleMessage(type, data, in: created)
        }
        created.onLinksChanged = { [weak self] status in
            DispatchQueue.main.async { self?.linksChanged(status) }
        }
        session = created
        macWantsPeerToPeer = false
        updatePeerToPeer()
        sessionMacID = hello.macID
        sessionMacName = hello.macName
        LinkHandshake.welcome(LinkWelcome(sessionID: created.id, iPadID: PairingStore.deviceID,
                                          iPadName: deviceName, received: 0, resumed: false,
                                          interface: link.interfaceClass), on: link)
        sessionQueue.async { [weak self] in
            self?.decoder.reset()
            created.attach(link, peerReceived: 0, rank: Self.rank(of: link))
        }
        beginSession(created)
    }

    private func beginSession(_ session: WireSession) {
        canvas?.resetVideo()
        connected = true
        status = L10n.tr("ipad.status.connected")
        stopVolumeForwarding()
        startVolumeForwarding()
        showDiagnostics = false
        captureStopped = false
        pairingServer?.answer(false)
        updatePairingListener()
        let screen = UIScreen.main.nativeBounds
        let logicalScreen = UIScreen.main.bounds
        var codecs: [String] = []
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) { codecs.append("hevc") }
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) { codecs.append("h264") }
        guard !codecs.isEmpty else {
            status = L10n.tr("ipad.error.decoder.unavailable")
            endSession()
            return
        }
        // Even sizes, as the Mac requires, rounded like the canvas sizes; an iPhone's are odd.
        let hello = DisplayHello(width: Int(max(screen.width, screen.height)) / 4 * 4,
                                 height: Int(min(screen.width, screen.height)) / 4 * 4,
                                 logicalWidth: Int(max(logicalScreen.width, logicalScreen.height)),
                                 logicalHeight: Int(min(logicalScreen.width, logicalScreen.height)),
                                 protocolVersion: Wire.version,
                                 hardwareDecoders: codecs,
                                 maximumFramesPerSecond: UIScreen.main.maximumFramesPerSecond,
                                 pixelsPerInch: Self.screenPixelsPerInch(),
                                 edrHeadroom: Double(UIScreen.main.potentialEDRHeadroom),
                                 wideColor: UIScreen.main.traitCollection.displayGamut == .P3,
                                 deviceKind: UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad",
                                 biometry: Self.biometry())
        if let payload = try? JSONEncoder().encode(hello) { session.send(.hello, payload) }
        brightnessObservation = NotificationCenter.default.addObserver(
            forName: UIScreen.brightnessDidChangeNotification, object: UIScreen.main, queue: .main
        ) { [weak self] _ in self?.sendBrightnessState() }
        sendBrightnessState()
        // The Mac starts at the full screen; the canvas tells it the actual area.
        sentSize = nil
        if let canvas { canvasResized(canvas.bounds.size) }
        telemetryTimer?.invalidate()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.sendTelemetry()
        }
    }

    /// A session outlives a lost link for a while, so a cable pull with no Wi-Fi path, or a
    /// brief Wi-Fi drop, resumes without starting over.
    private func linksChanged(_ status: WireSession.LinkStatus) {
        route = status
        linklessEnd?.cancel()
        linklessEnd = nil
        guard !status.usb, !status.wifi, session != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.endSession(status: L10n.tr("ipad.status.disconnected")) }
        linklessEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func endSession(status newStatus: String? = nil) {
        linklessEnd?.cancel()
        linklessEnd = nil
        if let session {
            sessionQueue.async { session.invalidate() }
        }
        session = nil
        sessionMacID = nil
        sessionMacName = nil
        route = WireSession.LinkStatus()
        telemetryTimer?.invalidate()
        if let brightnessObservation { NotificationCenter.default.removeObserver(brightnessObservation) }
        brightnessObservation = nil
        captureStopped = false
        if connected {
            connected = false
            stopVolumeForwarding()
            canvas?.resetVideo()
        }
        if let newStatus { status = newStatus }
        macWantsPeerToPeer = false
        updatePeerToPeer()
        updatePairingListener()
    }

    private func scheduleListenerRestart() {
        guard !listenerRestartScheduled else { return }
        listenerRestartScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.listenerRestartScheduled = false
            if UIApplication.shared.applicationState == .active { self.start() }
        }
    }

    /// The kind of Touch ID, Face ID or Optic ID this device has, for the Mac to name it.
    private static func biometry() -> String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .touchID: return "touchID"
        case .faceID: return "faceID"
        case .opticID: return "opticID"
        default: return nil
        }
    }

    private static func screenPixelsPerInch() -> Int {
        var machine = utsname()
        uname(&machine)
        let identifier = withUnsafeBytes(of: &machine.machine) { bytes in
            String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        // iPad mini 5, 6 and A17 Pro have 326 ppi; supported full-size iPads use 264 ppi.
        if ["iPad11,1", "iPad11,2", "iPad14,1", "iPad14,2", "iPad16,1", "iPad16,2"]
            .contains(identifier) { return 326 }
        return 264
    }

    private func startVolumeForwarding() {
        guard connected, UIApplication.shared.applicationState == .active,
              volumeObservation == nil else { return }
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.ambient)
            try audio.setActive(true)
            volumeSessionActive = true
        } catch {
            status = L10n.tr("ipad.error.volume", error.localizedDescription)
            return
        }
        originalVolume = audio.outputVolume
        volumeBaseline = min(0.9, max(0.1, audio.outputVolume))
        volumeReady = false
        let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 100, height: 20))
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow }) {
            window.addSubview(view)
        }
        volumeView = view
        view.layoutIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.volumeView?.layoutIfNeeded()
            self.setIPadVolume(self.volumeBaseline)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.volumeObservation != nil else { return }
                self.volumeBaseline = audio.outputVolume
                self.volumeReady = true
            }
        }
        volumeObservation = audio.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let volume = change.newValue else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.volumeReady else {
                    self.volumeBaseline = volume
                    return
                }
                guard self.connected, UIApplication.shared.applicationState == .active,
                      self.volumeObservation != nil,
                      abs(volume - self.volumeBaseline) > 0.001 else { return }
                self.sendVolumeStep(volume > self.volumeBaseline ? 1 : -1)
                self.setIPadVolume(self.volumeBaseline)
            }
        }
    }

    private func stopVolumeForwarding() {
        volumeObservation = nil
        volumeReady = false
        if let originalVolume { setIPadVolume(originalVolume) }
        originalVolume = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
        if volumeSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false)
            volumeSessionActive = false
        }
    }

    private func setIPadVolume(_ value: Float) {
        guard let slider = volumeSlider else { return }
        slider.value = value
        slider.sendActions(for: .valueChanged)
    }

    private var volumeSlider: UISlider? {
        guard let volumeView else { return nil }
        func find(in view: UIView) -> UISlider? {
            if let slider = view as? UISlider { return slider }
            for child in view.subviews {
                if let slider = find(in: child) { return slider }
            }
            return nil
        }
        return find(in: volumeView)
    }

    func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            needsFreshConnection = true
            stopVolumeForwarding()
        case .inactive:
            stopVolumeForwarding()
        case .active:
            if needsFreshConnection {
                needsFreshConnection = false
                endSession(status: L10n.tr("ipad.status.waiting"))
                stopListeners()
                sessionQueue.async { [weak self] in self?.decoder.reset() }
                scheduleListenerRestart()
            } else {
                startVolumeForwarding()
            }
        @unknown default: break
        }
    }

    private func sendVolumeStep(_ direction: Int) {
        guard let session, connected,
              let data = try? JSONEncoder().encode(VolumeStep(direction: direction)) else { return }
        session.send(.volumeStep, data)
    }

    private func sendBrightnessState() {
        guard let session, connected,
              let data = try? JSONEncoder().encode(BrightnessLevel(value: Double(UIScreen.main.brightness))) else { return }
        session.send(.brightnessState, data)
    }

    /// Runs on the session queue.
    private func handleMessage(_ type: UInt8, _ data: Data, in session: WireSession) {
        if type == WireType.videoFormat.rawValue,
           let format = try? JSONDecoder().decode(VideoFormat.self, from: data) {
            do { try decoder.configure(format) }
            catch { DispatchQueue.main.async { self.videoStatus = error.localizedDescription } }
        } else if type == WireType.videoFrame.rawValue {
            let start = ProcessInfo.processInfo.systemUptime
            do {
                try decoder.decode(data)
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                DispatchQueue.main.async {
                    self.decodedFrames += 1
                    self.totalDecodeMS += elapsed
                }
            } catch { DispatchQueue.main.async { self.videoStatus = error.localizedDescription; self.droppedFrames += 1 } }
        } else if type == WireType.telemetry.rawValue,
                  let report = try? JSONDecoder().decode(VideoTelemetry.self, from: data) {
            DispatchQueue.main.async {
                self.macVideoStatus = L10n.tr("ipad.telemetry.mac", report.frames,
                                              report.averageProcessingMS, report.queuedBytes / 1024)
            }
        } else if type == WireType.diagnostics.rawValue,
                  let control = try? JSONDecoder().decode(DiagnosticsControl.self, from: data) {
            DispatchQueue.main.async { self.showDiagnostics = control.visible }
        } else if type == WireType.brightnessSet.rawValue,
                  let request = try? JSONDecoder().decode(BrightnessLevel.self, from: data),
                  request.value.isFinite, (0...1).contains(request.value) {
            DispatchQueue.main.async {
                guard self.session === session, self.connected else { return }
                UIScreen.main.brightness = CGFloat(request.value)
                self.sendBrightnessState()
            }
        } else if type == WireType.capture.rawValue, let flag = data.first {
            DispatchQueue.main.async { self.captureStopped = flag == 0 }
        } else if type == WireType.peerToPeer.rawValue, let flag = data.first {
            DispatchQueue.main.async {
                self.macWantsPeerToPeer = flag == 1
                self.updatePeerToPeer()
            }
        } else if type == WireType.keySetup.rawValue {
            DispatchQueue.main.async { self.setUpKeys(for: session) }
        } else if type == WireType.signRequest.rawValue,
                  let request = try? JSONDecoder().decode(SignRequest.self, from: data) {
            DispatchQueue.main.async { self.sign(request, for: session) }
        } else if type == WireType.pairingRequest.rawValue {
            // Only over the USB tunnel: plugging in is what authorizes a new Mac.
            guard session.has(.usb) else { return }
            DispatchQueue.main.async { self.provideKey(to: session) }
        }
    }

    private let signingQueue = DispatchQueue(label: "WiredPad.signing")

    /// Makes this Mac's keys once the user confirms, and sends the Mac their public halves.
    private func setUpKeys(for session: WireSession) {
        guard session === self.session, let macID = sessionMacID else { return }
        let reason = L10n.tr("ipad.signing.setup", sessionMacName ?? "Mac")
        signingQueue.async { [deviceName] in
            let answer: DeviceKeys
            do {
                answer = DeviceKeys(keys: try DeviceKeyStore.setUp(mac: macID, reason: reason),
                                    deviceName: deviceName, error: nil)
            } catch {
                answer = DeviceKeys(keys: [:], deviceName: deviceName, error: error.localizedDescription)
            }
            if let data = try? JSONEncoder().encode(answer) { session.send(.deviceKeys, data) }
        }
    }

    /// Signs for the Mac once the user confirms with Touch ID or Face ID. One request at a time.
    private func sign(_ request: SignRequest, for session: WireSession) {
        guard session === self.session, let macID = sessionMacID else { return }
        signingQueue.async {
            var response: SignResponse
            do {
                let signature = try DeviceKeyStore.sign(request.data, for: request.purpose, mac: macID,
                                                        reason: request.reason)
                response = SignResponse(id: request.id, signature: signature, error: nil)
            } catch {
                linkLog.error("signing failed: \(error.localizedDescription, privacy: .public)")
                response = SignResponse(id: request.id, signature: nil, error: error.localizedDescription)
            }
            if let data = try? JSONEncoder().encode(response) { session.send(.signResponse, data) }
        }
    }

    private func provideKey(to session: WireSession) {
        guard session === self.session, let macID = sessionMacID else { return }
        let key = pairing.key(for: macID) ?? PairingStore.newKey()
        pairing.save(peerID: macID, name: sessionMacName ?? "Mac", key: key)
        pairedMacs = pairing.peers
        let message = PairingKeyMessage(iPadID: PairingStore.deviceID, iPadName: deviceName, key: key)
        if let data = try? JSONEncoder().encode(message) { session.send(.pairingKey, data) }
        restartWiFiListener()
    }

    func sendTouches(_ points: [TouchPoint]) {
        guard let session, connected,
              let data = try? JSONEncoder().encode(TouchPacket(points: points)) else { return }
        session.send(.touches, data)
    }

    func sendPen(_ samples: [PenSample]) {
        guard let session, connected, !samples.isEmpty,
              let data = try? JSONEncoder().encode(PenPacket(samples: samples)) else { return }
        session.send(.pen, data)
    }

    func sendPenDoubleTap() {
        guard let session, connected else { return }
        session.send(.penDoubleTap, Data())
    }

    private var sentSize: DisplaySize?
    private var pendingResize: DispatchWorkItem?

    /// Asks the Mac to match the video area once it has settled: a rotation or window
    /// resize passes through sizes on its way.
    fileprivate func canvasResized(_ points: CGSize) {
        guard points.width >= 120, points.height >= 120 else { return }
        let scale = UIScreen.main.nativeScale
        // HiDPI needs exactly twice the points in pixels, so keep both even.
        func pixels(_ value: CGFloat) -> Int { max(4, Int(value * scale) / 4 * 4) }
        let width = pixels(points.width), height = pixels(points.height)
        let size = DisplaySize(width: width, height: height, logicalWidth: Int(Double(width) / scale),
                               logicalHeight: Int(Double(height) / scale))
        pendingResize?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let session = self.session, self.connected, size != self.sentSize,
                  let data = try? JSONEncoder().encode(size) else { return }
            self.sentSize = size
            session.send(.displaySize, data)
        }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func sendTelemetry() {
        guard let session, connected else { return }
        let report = VideoTelemetry(side: "ipad", frames: decodedFrames,
                                    droppedFrames: droppedFrames + max(0, decodedFrames - displayedFrames - droppedFrames),
                                    averageProcessingMS: decodedFrames > 0 ? totalDecodeMS / Double(decodedFrames) : 0,
                                    queuedBytes: 0, bitRate: 0)
        let path = route.usb ? (route.wifi ? "USB+Wi-Fi" : "USB") : (route.wifi ? "Wi-Fi" : "-")
        videoStatus = L10n.tr("ipad.telemetry.video", decodedFrames, report.averageProcessingMS,
                              displayedFrames, report.droppedFrames, macVideoStatus) + " / " + path
        if let data = try? JSONEncoder().encode(report) { session.send(.telemetry, data) }
        decodedFrames = 0
        displayedFrames = 0
        droppedFrames = 0
        totalDecodeMS = 0
    }
}

private struct TouchScreen: UIViewRepresentable {
    let session: PadSession
    let onTouches: ([TouchPoint]) -> Void

    func makeUIView(context: Context) -> TouchCanvas {
        let canvas = TouchCanvas()
        canvas.onTouches = onTouches
        canvas.onPen = { [weak session] samples in session?.sendPen(samples) }
        canvas.onPenDoubleTap = { [weak session] in session?.sendPenDoubleTap() }
        canvas.onResize = { [weak session] size in session?.canvasResized(size) }
        session.canvas = canvas
        return canvas
    }

    func updateUIView(_ uiView: TouchCanvas, context: Context) {
        session.canvas = uiView
        uiView.onTouches = onTouches
    }
}

private final class TouchCanvas: UIView {
    private let videoLayer = AVSampleBufferDisplayLayer()
    var onTouches: (([TouchPoint]) -> Void)?
    var onPen: (([PenSample]) -> Void)?
    var onPenDoubleTap: (() -> Void)?
    var onResize: ((CGSize) -> Void)?
    private var fingers: [ObjectIdentifier: (Int, CGPoint)] = [:]
    private var penHovering = false
    private var penTouching = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black
        // While the Mac catches up with a rotation or window resize, frames of the old shape
        // are fitted rather than stretched.
        videoLayer.videoGravity = .resizeAspect
        // Video in a layer is tone mapped to SDR unless the layer asks for the full range.
        if #available(iOS 26.0, *) {
            videoLayer.preferredDynamicRange = .high
        } else {
            videoLayer.wantsExtendedDynamicRangeContent = true
        }
        layer.addSublayer(videoLayer)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        videoLayer.frame = bounds
        onResize?(bounds.size)
    }

    func display(_ image: CVPixelBuffer) -> Bool {
        guard videoLayer.isReadyForMoreMediaData else { return false }
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: image,
                                                           formatDescriptionOut: &description) == noErr,
              let description else { return false }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: .invalid,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: image,
                                                       formatDescription: description,
                                                       sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { return false }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        videoLayer.enqueue(sample)
        return true
    }

    func resetVideo() {
        videoLayer.flushAndRemoveImage()
    }

    private func penSample(at location: CGPoint, pressure: Double, altitude: CGFloat, azimuth: CGFloat,
                           roll: CGFloat?, touching: Bool, inRange: Bool) -> PenSample {
        PenSample(x: max(0, min(1, location.x / max(1, bounds.width))),
                  y: max(0, min(1, location.y / max(1, bounds.height))),
                  pressure: pressure, altitude: Double(altitude) * 180 / .pi,
                  azimuth: Double(azimuth) * 180 / .pi, touching: touching, inRange: inRange,
                  roll: roll.map { Double($0) * 180 / .pi })
    }

    /// Sends the Pencil's samples since the last event, so fast strokes keep their shape.
    private func pen(_ touches: Set<UITouch>, with event: UIEvent?, ended: Bool) {
        guard let touch = touches.first(where: { $0.type == .pencil }) else { return }
        penTouching = !ended
        let moves = ended ? [touch] : (event?.coalescedTouches(for: touch) ?? [touch])
        let samples = moves.map { move in
            penSample(at: move.preciseLocation(in: self),
                      pressure: move.maximumPossibleForce > 0 ? min(1, Double(move.force / move.maximumPossibleForce)) : 1,
                      altitude: move.altitudeAngle, azimuth: move.azimuthAngle(in: self),
                      roll: { if #available(iOS 17.5, *) { move.rollAngle } else { nil } }(),
                      touching: !ended, inRange: !ended)
        }
        onPen?(samples)
    }

    /// A Pencil above the screen, on iPads that sense it; a pointer hovers at no height.
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard #available(iOS 16.4, *) else { return }
        // Touching ends the hover; the touch itself carries the Pencil until it lifts.
        guard !penTouching else { penHovering = false; return }
        let inRange = (recognizer.state == .began || recognizer.state == .changed) && recognizer.zOffset > 0
        guard inRange || penHovering else { return }
        penHovering = inRange
        onPen?([penSample(at: recognizer.location(in: self), pressure: 0,
                          altitude: recognizer.altitudeAngle, azimuth: recognizer.azimuthAngle(in: self),
                          roll: { if #available(iOS 17.5, *) { recognizer.rollAngle } else { nil } }(),
                          touching: false, inRange: inRange)])
    }

    private func update(_ touches: Set<UITouch>, ended: Bool) {
        let touches = touches.filter { $0.type != .pencil }
        guard !touches.isEmpty else { return }
        for touch in touches {
            let key = ObjectIdentifier(touch)
            if ended { fingers.removeValue(forKey: key); continue }
            let id = fingers[key]?.0 ?? (0..<10).first(where: { n in !fingers.values.contains(where: { $0.0 == n }) })
            guard let id else { continue }
            fingers[key] = (id, touch.location(in: self))
        }
        let points = fingers.values.map { id, location in
            TouchPoint(id: id,
                       x: max(0, min(1, location.x / max(1, bounds.width))),
                       y: max(0, min(1, location.y / max(1, bounds.height))),
                       down: true)
        }
        onTouches?(points)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        pen(touches, with: event, ended: false); update(touches, ended: false)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        pen(touches, with: event, ended: false); update(touches, ended: false)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        pen(touches, with: event, ended: true); update(touches, ended: true)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        pen(touches, with: event, ended: true); update(touches, ended: true)
    }
}

// A double tap goes to the Mac, which hands it to apps as a change of mode, as Sidecar does;
// what it changes is up to each Mac app, not the iPad's double-tap setting.
extension TouchCanvas: UIPencilInteractionDelegate {
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        onPenDoubleTap?()
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        onPenDoubleTap?()
    }
}

/// The iPad side of numeric-comparison pairing. The iPad commits to its nonce first, shows
/// the code, and hands over this Mac's key, encrypted, only after the person allows it here.
private final class PairingServer {
    var onPrompt: ((String, String) -> Void)?
    var onFinish: ((Bool) -> Void)?

    private let link: NetworkLink
    private let store: PairingStore
    private let iPadName: String
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let iPadNonce = PairingCrypto.nonce()
    private var request: PairStart?
    private var macNonce: Data?
    private var finished = false
    private let queue = DispatchQueue(label: "WiredPad.pairing")

    init(link: NetworkLink, store: PairingStore, iPadName: String) {
        self.link = link
        self.store = store
        self.iPadName = iPadName
    }

    func start() {
        link.inbox.setHandler { [weak self] type, data in self?.queue.async { self?.receive(type, data) } }
        link.onClose = { [weak self] in self?.queue.async { self?.finish(false) } }
        link.start()
        queue.asyncAfter(deadline: .now() + 120) { [weak self] in self?.finish(false) }
    }

    func answer(_ allow: Bool) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            guard allow, let start = self.request, let macNonce = self.macNonce,
                  let macKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: start.publicKey),
                  let shared = try? self.privateKey.sharedSecretFromKeyAgreement(with: macKey) else {
                return self.finish(false)
            }
            let key = self.store.key(for: start.macID) ?? PairingStore.newKey()
            let sealingKey = PairingCrypto.sealingKey(shared: shared, macNonce: macNonce, iPadNonce: self.iPadNonce)
            guard let sealed = try? AES.GCM.seal(key, using: sealingKey).combined,
                  let data = try? JSONEncoder().encode(PairSealedKey(sealed: sealed)) else { return self.finish(false) }
            self.link.send(Wire.packet(.pairSealedKey, data))
            self.store.save(peerID: start.macID, name: start.macName, key: key)
            self.finish(true)
        }
    }

    private func receive(_ type: UInt8, _ data: Data) {
        let decoder = JSONDecoder()
        switch type {
        case WireType.pairStart.rawValue where request == nil:
            guard let message = try? decoder.decode(PairStart.self, from: data), message.publicKey.count == 32 else {
                return finish(false)
            }
            request = message
            let publicKey = privateKey.publicKey.rawRepresentation
            let commit = PairCommit(iPadID: PairingStore.deviceID, iPadName: iPadName, publicKey: publicKey,
                                    commitment: PairingCrypto.commitment(iPadKey: publicKey, macKey: message.publicKey,
                                                                         iPadNonce: iPadNonce))
            send(.pairCommit, commit)
        case WireType.pairNonce.rawValue where request != nil && macNonce == nil:
            guard let start = request, let message = try? decoder.decode(PairNonce.self, from: data),
                  message.nonce.count == 32 else { return finish(false) }
            macNonce = message.nonce
            send(.pairReveal, PairNonce(nonce: iPadNonce))
            let code = PairingCrypto.code(macKey: start.publicKey, iPadKey: privateKey.publicKey.rawRepresentation,
                                          macNonce: message.nonce, iPadNonce: iPadNonce)
            let name = start.macName
            DispatchQueue.main.async { [weak self] in self?.onPrompt?(name, code) }
        default:
            finish(false)
        }
    }

    private func send<T: Encodable>(_ type: WireType, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        link.send(Wire.packet(type, data))
    }

    private func finish(_ paired: Bool) {
        guard !finished else { return }
        finished = true
        link.onClose = nil
        if paired {
            queue.asyncAfter(deadline: .now() + 1) { [link] in link.close() }
        } else {
            link.close()
        }
        DispatchQueue.main.async { [weak self] in self?.onFinish?(paired) }
    }
}
