import CryptoKit
import Foundation
import Network
import SystemConfiguration

/// Finds iPads advertising WiredPad over Bonjour, on the same network or peer-to-peer Wi-Fi.
final class WirelessDirectory: ObservableObject {
    struct NearbyPad: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    /// iPads ready for an encrypted session, by iPad ID.
    @Published private(set) var sessionPads: [String: NearbyPad] = [:]
    /// The last place each iPad was seen. A Bonjour endpoint names the service, not an address,
    /// so it still works while the iPad briefly drops out of the results, as it does when it
    /// joins or leaves a network.
    private(set) var lastSeenPads: [String: NearbyPad] = [:]
    /// iPads currently showing their waiting screen and accepting pairing.
    @Published private(set) var pairablePads: [NearbyPad] = []

    private var sessionBrowser: NWBrowser?
    private var pairingBrowser: NWBrowser?

    /// Whether to look over peer-to-peer Wi-Fi too. Browsing that way keeps AWDL running,
    /// which slows the Wi-Fi network, so it is on only while the iPad cannot be found otherwise.
    var peerToPeer = false {
        didSet {
            guard peerToPeer != oldValue, sessionBrowser != nil else { return }
            sessionBrowser?.cancel(); sessionBrowser = nil
            pairingBrowser?.cancel(); pairingBrowser = nil
            start()
        }
    }

    func start() {
        guard sessionBrowser == nil else { return }
        sessionBrowser = browse(Wire.sessionService) { [weak self] pads in
            let found = Dictionary(pads.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            self?.sessionPads = found
            self?.lastSeenPads.merge(found) { _, new in new }
        }
        pairingBrowser = browse(Wire.pairingService) { [weak self] pads in
            self?.pairablePads = pads.sorted { $0.name < $1.name }
        }
    }

    private func browse(_ type: String, update: @escaping ([NearbyPad]) -> Void) -> NWBrowser {
        let parameters = NWParameters()
        parameters.includePeerToPeer = peerToPeer
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            let pads = results.compactMap { result -> NearbyPad? in
                guard case let .bonjour(txt) = result.metadata, let id = txt["id"] else { return nil }
                return NearbyPad(id: id, name: txt["name"] ?? id, endpoint: result.endpoint)
            }
            DispatchQueue.main.async { update(pads) }
        }
        browser.stateUpdateHandler = { [weak browser] state in
            if case .failed = state {
                browser?.cancel()
            }
        }
        browser.start(queue: .main)
        return browser
    }
}

/// This Mac's network interfaces, used to steer a link onto one path.
final class LocalInterfaces {
    /// Wi-Fi and Ethernet interfaces on a network. The USB cable's own network is left out.
    private(set) var network: [NWInterface] = []
    private(set) var hasWiredNetwork = false
    private let wifi = NWPathMonitor(requiredInterfaceType: .wifi)
    private let wired = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private var wifiInterfaces: [NWInterface] = []
    private var wiredInterfaces: [NWInterface] = []

    init() {
        wifi.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.wifiInterfaces = path.availableInterfaces; self?.update() }
        }
        wired.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.wiredInterfaces = path.availableInterfaces; self?.update() }
        }
        wifi.start(queue: .main)
        wired.start(queue: .main)
    }

    deinit {
        wifi.cancel()
        wired.cancel()
    }

    private func update() {
        let ports = Self.networkPorts()
        let wiredNetwork = wiredInterfaces.filter { $0.type == .wiredEthernet && ports.contains($0.name) }
        hasWiredNetwork = !wiredNetwork.isEmpty
        network = wifiInterfaces.filter { $0.type == .wifi } + wiredNetwork
    }

    /// Interfaces of configured network ports. The USB cable's own network is not one.
    static func networkPorts() -> Set<String> {
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        return Set(interfaces.compactMap { SCNetworkInterfaceGetBSDName($0) as String? })
    }
}

/// The Mac side of numeric-comparison pairing.
final class PairingClient {
    enum Outcome { case paired(iPadID: String, name: String), failed, cancelled }

    var onCode: ((String, String) -> Void)?
    var onFinish: ((Outcome) -> Void)?

    private let link: NetworkLink
    private let store: PairingStore
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let macNonce = PairingCrypto.nonce()
    private var commit: PairCommit?
    private var iPadNonce: Data?
    private var sealed: Data?
    private var approved = false
    private var finished = false
    private let queue = DispatchQueue(label: "WiredPad.pairing")

    init(endpoint: NWEndpoint, store: PairingStore) {
        self.store = store
        link = NetworkLink(kind: .wifi,
                           connection: NWConnection(to: endpoint, using: SecureTransport.pairingParameters()),
                           queue: queue)
    }

    func start() {
        link.onReady = { [weak self] in
            guard let self else { return }
            let start = PairStart(macID: PairingStore.deviceID, macName: Host.current().localizedName ?? "Mac",
                                  publicKey: self.privateKey.publicKey.rawRepresentation)
            self.send(.pairStart, start)
        }
        link.inbox.setHandler { [weak self] type, data in self?.queue.async { self?.receive(type, data) } }
        link.onClose = { [weak self] in self?.queue.async { self?.finish(.failed) } }
        link.start()
        queue.asyncAfter(deadline: .now() + 120) { [weak self] in self?.finish(.failed) }
    }

    /// Call after the person confirms that both screens show the same code.
    func approve() {
        queue.async { [weak self] in
            guard let self else { return }
            self.approved = true
            self.completeIfReady()
        }
    }

    func cancel() {
        queue.async { [weak self] in self?.finish(.cancelled) }
    }

    private func receive(_ type: UInt8, _ data: Data) {
        let decoder = JSONDecoder()
        switch type {
        case WireType.pairCommit.rawValue where commit == nil:
            guard let message = try? decoder.decode(PairCommit.self, from: data) else { return finish(.failed) }
            commit = message
            send(.pairNonce, PairNonce(nonce: macNonce))
        case WireType.pairReveal.rawValue where commit != nil && iPadNonce == nil:
            guard let commit, let reveal = try? decoder.decode(PairNonce.self, from: data),
                  PairingCrypto.commitment(iPadKey: commit.publicKey, macKey: privateKey.publicKey.rawRepresentation,
                                           iPadNonce: reveal.nonce) == commit.commitment else { return finish(.failed) }
            iPadNonce = reveal.nonce
            let code = PairingCrypto.code(macKey: privateKey.publicKey.rawRepresentation, iPadKey: commit.publicKey,
                                          macNonce: macNonce, iPadNonce: reveal.nonce)
            let name = commit.iPadName
            DispatchQueue.main.async { [weak self] in self?.onCode?(code, name) }
        case WireType.pairSealedKey.rawValue where iPadNonce != nil:
            guard let message = try? decoder.decode(PairSealedKey.self, from: data) else { return finish(.failed) }
            sealed = message.sealed
            completeIfReady()
        default:
            finish(.failed)
        }
    }

    private func completeIfReady() {
        guard approved, !finished, let sealed, let commit, let iPadNonce else { return }
        guard let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: commit.publicKey),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let key = try? AES.GCM.open(box, using: PairingCrypto.sealingKey(shared: shared, macNonce: macNonce,
                                                                                iPadNonce: iPadNonce)),
              key.count == 32 else { return finish(.failed) }
        store.save(peerID: commit.iPadID, name: commit.iPadName, key: key)
        finish(.paired(iPadID: commit.iPadID, name: commit.iPadName))
    }

    private func send<T: Encodable>(_ type: WireType, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        link.send(Wire.packet(type, data))
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        link.onClose = nil
        if case .paired = outcome {
            // Give the last packet a moment to flush before closing.
            queue.asyncAfter(deadline: .now() + 0.5) { [link] in link.close() }
        } else {
            link.close()
        }
        DispatchQueue.main.async { [weak self] in self?.onFinish?(outcome) }
    }
}
