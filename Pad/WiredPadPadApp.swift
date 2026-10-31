import SwiftUI
import UIKit
import Network
import AVFoundation
import CoreMedia
import VideoToolbox
import MediaPlayer

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
                    PadWaitingView(status: session.status)
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

private struct PadWaitingView: View {
    let status: String

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "macbook.and.ipad")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.4))
                .symbolEffect(.pulse)
            VStack(spacing: 8) {
                Text(status)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                Text(verbatim: nativeMode)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: 480)
        .padding(32)
    }

    private var nativeMode: String {
        let screen = UIScreen.main
        let size = screen.nativeBounds.size
        let width = Int(max(size.width, size.height))
        let height = Int(min(size.width, size.height))
        return "\(width) × \(height) · \(screen.maximumFramesPerSecond) Hz"
    }
}

final class PadSession: ObservableObject {
    @Published var status = L10n.tr("ipad.status.waiting")
    @Published var connected = false
    @Published var videoStatus = L10n.tr("ipad.video.waiting")
    @Published var showDiagnostics = false
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
    private var needsFreshConnection = false

    private let queue = DispatchQueue(label: "WiredPad.network", qos: .userInteractive)
    private var listener: NWListener?
    private var listenerRestartScheduled = false
    private var connection: NWConnection?

    init() { start() }

    private func start() {
        guard listener == nil else { return }
        do {
            let port = NWEndpoint.Port(rawValue: Wire.port)!
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.listener === listener else {
                    connection.cancel()
                    return
                }
                self.connection?.cancel()
                self.connection = connection
                self.decoder.reset()
                DispatchQueue.main.async { self.canvas?.resetVideo() }
                connection.stateUpdateHandler = { [weak self] state in
                    DispatchQueue.main.async {
                        guard let self, self.connection === connection else { return }
                        switch state {
                        case .ready:
                            self.connected = true
                            self.status = L10n.tr("ipad.status.connected")
                            self.stopVolumeForwarding()
                            self.startVolumeForwarding()
                            self.showDiagnostics = false
                            let screen = UIScreen.main.nativeBounds
                            let logicalScreen = UIScreen.main.bounds
                            var codecs: [String] = []
                            if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) { codecs.append("hevc") }
                            if VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) { codecs.append("h264") }
                            let hello = DisplayHello(width: Int(max(screen.width, screen.height)),
                                                     height: Int(min(screen.width, screen.height)),
                                                     logicalWidth: Int(max(logicalScreen.width, logicalScreen.height)),
                                                     logicalHeight: Int(min(logicalScreen.width, logicalScreen.height)),
                                                     protocolVersion: Wire.version,
                                                     hardwareDecoders: codecs,
                                                     maximumFramesPerSecond: UIScreen.main.maximumFramesPerSecond,
                                                     pixelsPerInch: Self.screenPixelsPerInch())
                            guard !codecs.isEmpty else {
                                self.status = L10n.tr("ipad.error.decoder.unavailable")
                                connection.cancel()
                                return
                            }
                            if let payload = try? JSONEncoder().encode(hello) {
                                connection.send(content: Wire.packet(.hello, payload), completion: .contentProcessed { _ in })
                            }
                            self.telemetryTimer?.invalidate()
                            self.telemetryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                                self?.sendTelemetry()
                            }
                            self.receiveHeader(connection)
                        case .failed(let error):
                            self.connected = false
                            self.stopVolumeForwarding()
                            self.status = L10n.tr("ipad.error.connection", error.localizedDescription)
                            self.telemetryTimer?.invalidate()
                        case .cancelled:
                            self.connected = false
                            self.stopVolumeForwarding()
                            self.status = L10n.tr("ipad.status.disconnected")
                            self.telemetryTimer?.invalidate()
                        default: break
                        }
                    }
                }
                connection.start(queue: self.queue)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    DispatchQueue.main.async {
                        guard let self, self.listener === listener else { return }
                        self.status = L10n.tr("ipad.error.listener", error.localizedDescription)
                        self.listener = nil
                        listener.cancel()
                        self.scheduleListenerRestart()
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            status = L10n.tr("ipad.error.listener.start", error.localizedDescription)
            scheduleListenerRestart()
        }
    }

    private func scheduleListenerRestart() {
        guard !listenerRestartScheduled else { return }
        listenerRestartScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.listenerRestartScheduled = false
            if self.listener == nil, UIApplication.shared.applicationState == .active {
                self.start()
            }
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
                let oldListener = listener
                listener = nil
                oldListener?.cancel()
                let oldConnection = connection
                connection = nil
                connected = false
                oldConnection?.cancel()
                telemetryTimer?.invalidate()
                canvas?.resetVideo()
                queue.async { [weak self] in self?.decoder.reset() }
                scheduleListenerRestart()
            } else {
                startVolumeForwarding()
            }
        @unknown default: break
        }
    }

    private func sendVolumeStep(_ direction: Int) {
        guard let connection, connected,
              let data = try? JSONEncoder().encode(VolumeStep(direction: direction)) else { return }
        connection.send(content: Wire.packet(.volumeStep, data), completion: .contentProcessed { _ in })
    }

    private func receiveHeader(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, complete, error in
            guard let self, self.connection === connection else { return }
            guard !complete, error == nil, let data, data.count == 5 else {
                DispatchQueue.main.async {
                    guard self.connection === connection else { return }
                    self.connected = false
                    self.stopVolumeForwarding()
                    self.status = L10n.tr("ipad.status.disconnected")
                }
                return
            }
            let length = data.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= UInt32(Wire.maxPayload) else { connection.cancel(); return }
            self.receivePayload(connection, type: data[0], length: Int(length))
        }
    }

    private func receivePayload(_ connection: NWConnection, type: UInt8, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, complete, error in
            guard let self, self.connection === connection else { return }
            guard !complete, error == nil, let data, data.count == length else {
                DispatchQueue.main.async {
                    guard self.connection === connection else { return }
                    self.connected = false
                    self.status = L10n.tr("ipad.error.video.stopped")
                }
                return
            }
            if type == WireType.videoFormat.rawValue,
               let format = try? JSONDecoder().decode(VideoFormat.self, from: data) {
                do { try self.decoder.configure(format) }
                catch { DispatchQueue.main.async { self.videoStatus = error.localizedDescription } }
            } else if type == WireType.videoFrame.rawValue {
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    try self.decoder.decode(data)
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
            }
            self.receiveHeader(connection)
        }
    }

    func sendTouches(_ points: [TouchPoint]) {
        guard let connection, connected,
              let data = try? JSONEncoder().encode(TouchPacket(points: points)) else { return }
        connection.send(content: Wire.packet(.touches, data), completion: .contentProcessed { _ in })
    }

    private func sendTelemetry() {
        guard let connection, connected else { return }
        let report = VideoTelemetry(side: "ipad", frames: decodedFrames,
                                    droppedFrames: droppedFrames + max(0, decodedFrames - displayedFrames - droppedFrames),
                                    averageProcessingMS: decodedFrames > 0 ? totalDecodeMS / Double(decodedFrames) : 0,
                                    queuedBytes: 0, bitRate: 0)
        videoStatus = L10n.tr("ipad.telemetry.video", decodedFrames, report.averageProcessingMS,
                              displayedFrames, report.droppedFrames, macVideoStatus)
        if let data = try? JSONEncoder().encode(report) {
            connection.send(content: Wire.packet(.telemetry, data), completion: .contentProcessed { _ in })
        }
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
    private var fingers: [ObjectIdentifier: (Int, CGPoint)] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black
        videoLayer.videoGravity = .resize
        layer.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); videoLayer.frame = bounds }

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

    private func update(_ touches: Set<UITouch>, ended: Bool) {
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches, ended: false) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches, ended: false) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches, ended: true) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches, ended: true) }
}
