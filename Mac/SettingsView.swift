import CryptoKit
import SwiftUI

/// The settings window, built like System Settings and Xcode's: a sidebar of panes, and
/// grouped sections in each. The General pane starts like System Settings' Displays, with the
/// Mac and the device side by side.
struct SettingsView: View {
    @ObservedObject var model: MacSession
    @ObservedObject var driver: DriverExtensionController

    enum Pane: String, CaseIterable, Identifiable {
        case general, devices, signing, diagnostics
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .general: return "mac.tab.general"
            case .devices: return "mac.tab.pairing"
            case .signing: return "mac.tab.signing"
            case .diagnostics: return "mac.diagnostics.title"
            }
        }
    }

    /// Settings open on the pane used last, as the guidelines ask.
    @AppStorage("WiredPad.settingsPane") private var pane = Pane.general
    @StateObject private var pictures = DesktopPictures()

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: Binding(get: { pane }, set: { if let new = $0 { pane = new } })) { item in
                Label(item.title, systemImage: symbol(item))
            }
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralPane(model: model, driver: driver)
                case .devices: DevicesPane(model: model)
                case .signing: SigningPane(model: model)
                case .diagnostics: DiagnosticsPane(model: model)
                }
            }
            .navigationTitle(pane.title)
        }
        .frame(width: 720, height: 480)
        .environmentObject(pictures)
        .task(id: model.displayID) { await pictures.load(deviceDisplay: model.displayID) }
        // sudo is set up from a terminal, so look again on coming back from one.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSigning()
        }
    }

    private func symbol(_ pane: Pane) -> String {
        switch pane {
        case .general: return "gearshape"
        case .devices: return "ipad.and.iphone"
        case .signing: return model.biometrySymbol
        case .diagnostics: return "waveform.path.ecg"
        }
    }
}

/// A pane's grouped form.
private struct Pane<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form { content() }
            .formStyle(.grouped)
    }
}

/// The top of a pane other than General: its symbol, its name and one line about it, as at the
/// top of System Settings' panes.
private struct PaneHeader: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var model: MacSession
    @ObservedObject var driver: DriverExtensionController

    var body: some View {
        Pane {
            Section {
                Stage(model: model) {
                    LinkIndicator(status: model.route, running: model.running)
                } deviceDetail: {
                    StatusLine(on: model.running,
                               text: model.running ? "mac.state.connected"
                                   : model.connecting ? "mac.state.connecting" : "mac.state.disconnected")
                }
                .help(model.status)
            }

            if model.running {
                Section {
                    ForEach(Array(specs.enumerated()), id: \.offset) { _, spec in
                        LabeledContent(spec.0) { Text(spec.1).monospacedDigit() }
                    }
                }
            } else {
                Section {
                    Text(L10n.tr("mac.permission.note", model.deviceNoun))
                        .foregroundStyle(.secondary)
                }
            }

            if let hidError = model.hidError { problem("mac.error.hid", hidError) }
            if let volumeError = model.volumeError { problem("mac.error.volume", volumeError) }

            if driver.isBundled || model.deviceSupportsHDR {
                Section {
                    // Only a device that can show HDR is offered it.
                    if model.deviceSupportsHDR {
                        Toggle(isOn: $model.hdrEnabled) {
                            Text("mac.hdr.toggle")
                            Text("mac.hdr.note")
                        }
                    }
                    if driver.isBundled {
                        LabeledContent {
                            Button("mac.driver.activate") { driver.activate() }
                        } label: {
                            Text("mac.driver.title")
                        }
                        .help(driver.status)
                    }
                }
            }
        }
    }

    /// The display's size, rate and codec, and the link, as rows.
    private var specs: [(LocalizedStringKey, String)] {
        let parts = model.displaySummary?.components(separatedBy: " · ") ?? []
        var rows: [(LocalizedStringKey, String)] = []
        if parts.count >= 3 {
            rows.append(("mac.spec.resolution", parts[0]))
            rows.append(("mac.spec.refresh", parts[1]))
            rows.append(("mac.spec.codec", parts[2...].joined(separator: " ")))
        }
        return rows
    }

    private func problem(_ title: LocalizedStringKey, _ detail: String) -> some View {
        Section {
            Label {
                Text(title)
                Text(detail).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
        }
    }
}

/// The top of every pane: the Mac, the pane's subject in the middle, and the device, each
/// showing its own desktop picture, like the arrangement in System Settings' Displays. See
/// docs/design.md.
private struct Stage<Middle: View, Detail: View, Device: View>: View {
    @ObservedObject var model: MacSession
    @EnvironmentObject private var pictures: DesktopPictures
    var macDetail: Text = Text("mac.arrangement.this")
    @ViewBuilder let middle: () -> Middle
    @ViewBuilder let deviceDetail: () -> Detail
    @ViewBuilder let device: () -> Device

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 8) {
                LaptopFigure(image: pictures.mac.map { Image(nsImage: $0) })
                Text(Host.current().localizedName ?? "Mac").font(.headline).lineLimit(1)
                macDetail.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(minWidth: 180)
            middle()
                .padding(.top, 30)
            VStack(spacing: 8) {
                device()
                deviceDetail()
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 150)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

extension Stage where Device == AnyView {
    /// The connected device, or the last one, showing its desktop picture.
    init(model: MacSession, macDetail: Text = Text("mac.arrangement.this"),
         @ViewBuilder middle: @escaping () -> Middle, @ViewBuilder deviceDetail: @escaping () -> Detail) {
        self.model = model
        self.macDetail = macDetail
        self.middle = middle
        self.deviceDetail = deviceDetail
        self.device = {
            AnyView(DeviceFigure(model: model))
        }
    }
}

/// The current device with its name.
private struct DeviceFigure: View {
    @ObservedObject var model: MacSession
    @EnvironmentObject private var pictures: DesktopPictures

    var body: some View {
        VStack(spacing: 8) {
            TabletFigure(image: pictures.device.map { Image(nsImage: $0) }, portrait: pictures.devicePortrait,
                         phone: model.deviceNoun == "iPhone", active: model.running)
                .frame(height: 113, alignment: .bottom)
            Text(model.deviceNoun).font(.headline)
        }
    }
}

/// A dot and a short state, under a figure.
private struct StatusLine: View {
    let on: Bool
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(on ? Color.green : Color.secondary).frame(width: 6, height: 6)
            Text(text)
        }
    }
}

/// The middle of the stage: a symbol on a line between the two devices, a title, and smaller
/// lines beneath. Accent when active, gray otherwise.
private struct Connector<Footer: View>: View {
    let symbol: String
    let active: Bool
    let title: String
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                line
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(active ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12)))
                line
            }
            Text(title)
                .font(.callout.weight(.semibold).monospacedDigit())
            footer()
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: 170)
    }

    private var line: some View {
        Capsule()
            .fill(active ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25))
            .frame(width: 44, height: 2)
    }
}

/// Each screen's desktop picture, as Displays shows them, rather than what is on it.
@MainActor
private final class DesktopPictures: ObservableObject {
    @Published var mac: NSImage?
    @Published var device: NSImage?
    @Published var devicePortrait = false

    func load(deviceDisplay: CGDirectDisplayID) async {
        let screens = NSScreen.screens
        let deviceScreen = screens.first { $0.displayID == deviceDisplay }
        let macScreen = screens.first { CGDisplayIsBuiltin($0.displayID) != 0 } ?? NSScreen.main
        devicePortrait = deviceScreen.map { $0.frame.height > $0.frame.width } ?? false
        mac = await Self.picture(macScreen)
        // Keep the last device's picture while none is connected.
        if let picture = await Self.picture(deviceScreen) { device = picture }
    }

    private static func picture(_ screen: NSScreen?) async -> NSImage? {
        guard let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return await Task.detached { NSImage(contentsOf: url) }.value
    }
}

/// Which link the video takes: the cable for USB, the waves for Wi‑Fi, and the link standing
/// by, smaller, beneath.
private struct LinkIndicator: View {
    let status: WireSession.LinkStatus
    let running: Bool

    var body: some View {
        let primary = running ? status.primaryRank : nil
        Connector(symbol: primary.map(Self.symbol) ?? "ellipsis", active: primary != nil,
                  title: primary.map(Self.name) ?? "") {
            ForEach(running ? status.ranks.filter { $0 != primary } : [], id: \.self) { rank in
                Label(L10n.tr("mac.link.standby", Self.name(rank)), systemImage: Self.symbol(rank))
            }
        }
    }

    /// USB is rank 0; the network paths follow, best first.
    private static func symbol(_ rank: Int) -> String {
        switch NetworkPath(rank: rank) {
        case nil: return "cable.connector"
        case .wiredLAN: return "network"
        case .peerToPeer, .wifiAware: return "antenna.radiowaves.left.and.right"
        case .wifiLAN: return "wifi"
        }
    }

    private static func name(_ rank: Int) -> String {
        NetworkPath(rank: rank).map { L10n.tr("mac.path.\(String(describing: $0))") } ?? L10n.tr("mac.route.usb")
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

private struct LaptopFigure: View {
    let image: Image?

    var body: some View {
        VStack(spacing: 0) {
            screen
                .frame(width: 150, height: 97)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.1)))
            UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.78), Color(white: 0.6)], startPoint: .top, endPoint: .bottom))
                .frame(width: 176, height: 6)
        }
    }

    @ViewBuilder private var screen: some View {
        if let image {
            image.resizable().aspectRatio(contentMode: .fill)
        } else {
            Color(white: 0.25)
        }
    }
}

private struct TabletFigure: View {
    let image: Image?
    let portrait: Bool
    let phone: Bool
    let active: Bool

    private var size: CGSize {
        let long: CGFloat = phone ? 112 : 128, short: CGFloat = phone ? 54 : 96
        return portrait ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
    }

    var body: some View {
        Group {
            if let image, active {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.18)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: phone ? 9 : 6, style: .continuous))
        .padding(phone ? 4 : 6)
        .background(RoundedRectangle(cornerRadius: phone ? 13 : 12, style: .continuous).fill(Color(white: 0.1)))
        .opacity(active ? 1 : 0.55)
        .animation(.default, value: portrait)
    }
}

// MARK: - Devices

private struct DevicesPane: View {
    @ObservedObject var model: MacSession

    var body: some View {
        Pane {
            PaneHeader(symbol: "ipad.and.iphone", title: "mac.tab.pairing", detail: "mac.header.devices")
            Section {
                if model.pairedPads.isEmpty {
                    Text("mac.pair.none").foregroundStyle(.secondary)
                }
                ForEach(model.pairedPads) { pad in
                    LabeledContent {
                        Button("mac.pair.forget") { model.forget(pad) }
                    } label: {
                        Label(pad.name, systemImage: "ipad.and.iphone")
                    }
                }
            } header: {
                Text("mac.pair.section")
            }
        }
    }
}

// MARK: - SSH and sudo

private struct SigningPane: View {
    @ObservedObject var model: MacSession

    var body: some View {
        Pane {
            PaneHeader(symbol: model.biometrySymbol, title: "mac.tab.signing",
                       detail: LocalizedStringKey(L10n.tr("mac.header.signing", model.deviceNoun, model.biometryName)))
            Section {
                if let setup = model.signingSetup {
                    LabeledContent(L10n.tr("mac.signing.key", setup.deviceName)) {
                        Button("mac.signing.forget") { model.forgetSigning() }
                    }
                } else {
                    LabeledContent(L10n.tr("mac.signing.none", model.deviceNoun, model.biometryName)) {
                        Button("mac.signing.setup") { model.setUpSigning() }
                            .disabled(!model.running)
                    }
                }
            } footer: {
                if !model.signingStatus.isEmpty { Text(model.signingStatus) }
            }

            if let setup = model.signingSetup {
                Section {
                    Toggle(isOn: Binding(get: { model.sshEnabled }, set: { model.setSSH($0) })) {
                        Text("mac.signing.ssh.title")
                        Text("mac.signing.ssh.note")
                    }
                    LabeledContent("mac.signing.fingerprint") {
                        HStack(spacing: 8) {
                            Text(Self.fingerprint(setup.ssh))
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    SSHKey.publicKeyLine(setup.ssh) + " WiredPad \(setup.deviceName)", forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.tr("mac.signing.copy"))
                        }
                    }
                } header: {
                    Text("SSH")
                }

                Section {
                    LabeledContent {
                        if let command = model.sudoState == .on ? SudoSetup.uninstallCommand : SudoSetup.installCommand {
                            Button(model.sudoState == .on ? "mac.signing.sudo.copyoff" : "mac.signing.sudo.copyon") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                                model.copiedSudoCommand()
                            }
                        }
                    } label: {
                        Text(model.sudoState == .on ? "mac.signing.sudo.on"
                             : model.sudoState == .stale ? "mac.signing.sudo.stale" : "mac.signing.sudo.off")
                        Text(L10n.tr("mac.signing.sudo.note", model.deviceNoun))
                    }
                } header: {
                    Text("sudo")
                }
            }
        }
    }

    /// The key's fingerprint as `ssh-keygen -l` prints it.
    static func fingerprint(_ publicKey: Data) -> String {
        let digest = SHA256.hash(data: SSHKey.blob(publicKey))
        return "SHA256:" + Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

// MARK: - Diagnostics

private struct DiagnosticsPane: View {
    @ObservedObject var model: MacSession

    var body: some View {
        Pane {
            PaneHeader(symbol: "waveform.path.ecg", title: "mac.diagnostics.title", detail: "mac.header.diagnostics")
            Section {
                LabeledContent("mac.stat.encode") {
                    Text(model.macReport.map {
                        String(format: "%d fps · %.1f ms · %d Mbps", $0.frames, $0.averageProcessingMS, $0.bitRate / 1_000_000)
                    } ?? "–").monospacedDigit()
                }
                LabeledContent(L10n.tr("mac.stat.decode", model.deviceNoun)) {
                    Text(model.ipadReport.map {
                        String(format: "%d fps · %.1f ms · %d %@", $0.frames, $0.averageProcessingMS, $0.droppedFrames,
                               L10n.tr("mac.stat.dropped"))
                    } ?? "–").monospacedDigit()
                }
                LabeledContent("mac.stat.touches") {
                    Text("\(model.maxReceivedTouches) / \(model.maxSentTouches)").monospacedDigit()
                }
                if !model.linkDiagnostics.isEmpty {
                    LabeledContent("mac.stat.links") { Text(model.linkDiagnostics).monospacedDigit() }
                }
            } header: {
                Text("mac.stat.section")
            }

            Section {
                Toggle(L10n.tr("mac.diagnostics.overlay", model.deviceNoun), isOn: Binding(
                    get: { model.showDiagnostics },
                    set: { if $0 != model.showDiagnostics { model.toggleDiagnostics() } }
                ))
                LabeledContent("mac.diagnostics.tools") {
                    HStack {
                        Button("mac.diagnostics.probe") { model.openTouchProbe() }
                        Button("mac.diagnostics.hidtest") { model.sendTestTouches() }
                        Button("mac.diagnostics.brightnessprobe") { model.probeBrightness() }
                        Button("mac.diagnostics.handover") { model.testHandover() }
                            .disabled(!(model.route.usb && model.route.wifi))
                    }
                    .disabled(model.displayID == 0)
                }
            } footer: {
                Text([L10n.tr("mac.diagnostics.selftest", model.selfTestStatus), model.brightnessDiagnostic]
                    .joined(separator: " · "))
            }
        }
    }
}
