import SwiftUI
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import Darwin

@main
struct WiredPadMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(model: delegate.model, driver: delegate.driver)
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
    @ObservedObject var driver: DriverExtensionController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.running ? "mac.state.connected" :
                (model.connecting ? "mac.state.connecting" : "mac.state.disconnected"))
        if model.running, let summary = model.displaySummary {
            Text(summary)
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("mac.diagnostics.touches", model.maxReceivedTouches, model.maxSentTouches))
                    Text(L10n.tr("mac.diagnostics.appkit", model.nativeTouchEvents, model.maxNativeTouches))
                    Text(L10n.tr("mac.diagnostics.selftest", model.selfTestStatus))
                    Text(model.macTelemetry)
                    Text(model.ipadTelemetry)
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

final class MacSession: NSObject, ObservableObject, SCStreamOutput {
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

    private var socketFD: Int32 = -1
    private var reconnectWanted = false
    private var reconnectScheduled = false
    private var manuallyStopped = false
    private var retrying = false
    private var connectionGeneration = 0
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "WiredPad.capture")
    private let sendQueue = DispatchQueue(label: "WiredPad.send")
    private var lastFrame = 0.0
    private var encoder: HardwareVideoEncoder?
    private let sendLock = NSLock()
    private var pendingVideoBytes = 0
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
        guard socketFD >= 0,
              let payload = try? JSONEncoder().encode(DiagnosticsControl(visible: showDiagnostics)) else { return }
        let packet = Wire.packet(.diagnostics, payload)
        sendQueue.async { [weak self] in self?.writePacket(packet) }
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
        if !retrying { status = L10n.tr("mac.status.searching") }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fd = WiredPadConnectUSB(Wire.port)
            DispatchQueue.main.async {
                guard let self else { if fd >= 0 { close(fd) }; return }
                guard self.connectionGeneration == generation, !self.manuallyStopped else {
                    if fd >= 0 { close(fd) }
                    return
                }
                if fd < 0 {
                    self.connecting = false
                    self.retrying = true
                    self.status = L10n.tr(String(cString: WiredPadUSBError()))
                    self.scheduleReconnect()
                    return
                }
                self.retrying = false
                self.socketFD = fd
                self.status = L10n.tr("mac.status.negotiating")
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let header = Self.readExactly(fd, 5),
                          header[0] == WireType.hello.rawValue else {
                        DispatchQueue.main.async {
                            guard self.connectionGeneration == generation, !self.manuallyStopped else { return }
                            self.status = L10n.tr("mac.error.handshake"); self.disconnect()
                        }
                        return
                    }
                    let length = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard length < 1024,
                          let data = Self.readExactly(fd, Int(length)),
                          let hello = try? JSONDecoder().decode(DisplayHello.self, from: data),
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
                        guard self.connectionGeneration == generation, !self.manuallyStopped else { return }
                        Task { await self.beginDisplay(hello: hello, generation: generation) }
                    }
                }
            }
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
            let helper = Process()
            helper.executableURL = Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("WiredPadModeHelper")
            helper.arguments = [String(id), String(width), String(height),
                                String(hello.logicalWidth), String(hello.logicalHeight)]
            let output = Pipe()
            helper.standardOutput = output
            try helper.run()
            helper.waitUntilExit()
            guard helper.terminationStatus == 0 else {
                status = L10n.tr("mac.error.mode")
                disconnect()
                return
            }
            let displayMode = String(data: output.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "native"
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
            displayMaximumFPS = selectedEncoder.frameRate
            targetFPS = selectedEncoder.frameRate
            lastFrame = 0
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(selectedEncoder.frameRate))
            config.queueDepth = 3
            config.showsCursor = true
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            self.stream = stream
            try await stream.startCapture()
            guard connectionGeneration == generation, !manuallyStopped else {
                try? await stream.stopCapture()
                return
            }
            connecting = false
            reconnectWanted = false
            running = true
            sendDiagnosticsControl()
            let timer = DispatchSource.makeTimerSource(queue: captureQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.sendVideoTelemetry() }
            timer.resume()
            videoTimer = timer
            displaySummary = L10n.tr("mac.menu.summary", width, height, hello.maximumFramesPerSecond,
                                     selectedEncoder.codec.uppercased())
            status = touchDevice != nil
                ? L10n.tr("mac.status.connected", width, height, hello.logicalWidth,
                          hello.logicalHeight, hello.pixelsPerInch, hello.maximumFramesPerSecond,
                          displayMode, selectedEncoder.codec.uppercased(), selectedEncoder.frameRate)
                : L10n.tr("mac.error.touchdevice")
            receiveTouches(generation: generation)
        } catch {
            guard connectionGeneration == generation, !manuallyStopped else { return }
            status = L10n.tr("mac.error.capture.start", error.localizedDescription)
            disconnect()
        }
    }

    private func disconnect() {
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
        if let stream {
            Task { try? await stream.stopCapture() }
            self.stream = nil
        }
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
        sendLock.lock()
        let congested = pendingVideoBytes > 2_000_000
        sendLock.unlock()
        guard !congested else { captureDrops += 1; return }
        lastFrame = now
        do {
            try encoder.encode(sampleBuffer)
        } catch {
            DispatchQueue.main.async { [weak self] in self?.status = error.localizedDescription }
        }
    }

    private func sendVideoTelemetry() {
        guard let encoder else { return }
        sendLock.lock()
        let queued = pendingVideoBytes
        sendLock.unlock()
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
            self.sendLock.lock()
            let queuedBytes = self.pendingVideoBytes
            self.sendLock.unlock()
            if queuedBytes > 1_000_000 {
                encoder.setBitRate(Int(Double(encoder.bitRate) * 0.85))
            } else if self.healthySeconds == 0 && report.droppedFrames == 0 {
                encoder.setBitRate(Int(Double(encoder.bitRate) * 1.05))
            }
        }
    }

    private func enqueueVideo(_ type: WireType, _ payload: Data) {
        let packet = Wire.packet(type, payload)
        sendLock.lock()
        pendingVideoBytes += packet.count
        sendLock.unlock()
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.writePacket(packet)
            self.sendLock.lock()
            self.pendingVideoBytes -= packet.count
            self.sendLock.unlock()
        }
    }

    private func writePacket(_ data: Data) {
        let fd = socketFD
        guard fd >= 0 else { return }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    private func receiveTouches(generation: Int) {
        let fd = socketFD
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            while fd >= 0 {
                guard let header = Self.readExactly(fd, 5) else { break }
                let type = header[0]
                let length = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length <= UInt32(Wire.maxPayload), let payload = Self.readExactly(fd, Int(length)) else { break }
                if type == WireType.touches.rawValue,
                   let packet = try? JSONDecoder().decode(TouchPacket.self, from: payload) {
                    DispatchQueue.main.async { self?.applyTouches(packet.points) }
                } else if type == WireType.volumeStep.rawValue,
                          let step = try? JSONDecoder().decode(VolumeStep.self, from: payload),
                          (step.direction == 1 || step.direction == -1) {
                    DispatchQueue.main.async {
                        guard let self else { return }
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
                } else if type == WireType.telemetry.rawValue,
                          let report = try? JSONDecoder().decode(VideoTelemetry.self, from: payload) {
                    self?.updateForIPad(report)
                    DispatchQueue.main.async {
                        self?.ipadTelemetry = L10n.tr("ipad.telemetry.report", report.frames,
                                                     report.averageProcessingMS, report.droppedFrames)
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.connectionGeneration == generation, !self.manuallyStopped else { return }
                self.status = L10n.tr("mac.status.reconnecting")
                self.reconnectWanted = true
                self.disconnect()
            }
        }
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var result = Data(count: count)
        let success = result.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return count == 0 }
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        return success ? result : nil
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
