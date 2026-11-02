import Foundation
import SystemExtensions

final class DriverExtensionController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static var identifier: String {
        let host = Bundle.main.bundleIdentifier ?? "com.example.wiredpad.WiredPadMac"
        return host.replacingOccurrences(of: ".WiredPadMac", with: ".WiredPadTouchDriver")
    }

    @Published private(set) var status = L10n.tr("driver.status.inactive")
    /// Runs once a new driver is active, for touch devices made before it to be made again.
    var onActivated: (() -> Void)?

    var isBundled: Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
            .appendingPathComponent("\(Self.identifier).dext", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path)
    }

    func activate() {
        guard isBundled else {
            status = L10n.tr("driver.error.notbundled")
            return
        }
        status = L10n.tr("driver.status.requesting")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.identifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = L10n.tr("driver.status.approval")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            status = L10n.tr("driver.status.active")
            onActivated?()
        case .willCompleteAfterReboot:
            status = L10n.tr("driver.status.reboot")
        @unknown default:
            status = L10n.tr("driver.status.result", result.rawValue)
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        status = L10n.tr("driver.error.activation", error.localizedDescription)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
}
