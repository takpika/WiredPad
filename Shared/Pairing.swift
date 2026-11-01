import CryptoKit
import Foundation
import Network
import Security

/// Small wrapper around the Keychain. Pairing keys never leave this device and are not synced.
enum KeychainStore {
    private static let service = "WiredPad.pairing"

    static func data(for account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func set(_ data: Data, for account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var item = baseQuery(account)
        item[kSecValueData as String] = data
        var protected = item
        protected[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(protected as CFDictionary, nil) != errSecSuccess {
            // The macOS file-based keychain may refuse the accessibility attribute.
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
}

/// Paired peers: names in user defaults, keys in the Keychain.
final class PairingStore {
    struct Peer: Codable, Identifiable, Equatable {
        let id: String
        var name: String
    }

    private let defaultsKey = "WiredPad.pairedPeers"

    /// This device's stable identifier.
    static let deviceID: String = {
        let key = "WiredPad.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }()

    var peers: [Peer] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Peer].self, from: data) else { return [] }
        return decoded.filter { key(for: $0.id) != nil }
    }

    func key(for peerID: String) -> Data? { KeychainStore.data(for: peerID) }

    func save(peerID: String, name: String, key: Data) {
        KeychainStore.set(key, for: peerID)
        var list = peers.filter { $0.id != peerID }
        list.append(Peer(id: peerID, name: name))
        write(list)
    }

    func remove(peerID: String) {
        KeychainStore.delete(peerID)
        write(peers.filter { $0.id != peerID })
    }

    private func write(_ list: [Peer]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

/// Encrypted, mutually authenticated Wi-Fi transport. Each Mac has its own pre-shared key,
/// identified by the Mac's ID, so a Mac can be removed without re-pairing the others.
enum SecureTransport {
    static func clientParameters(macID: String, key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        addKey(key, identity: macID, to: tls)
        return parameters(tls)
    }

    /// Offering peer-to-peer Wi-Fi keeps AWDL running, which slows the Wi-Fi network, so the
    /// listener offers it only when asked.
    static func serverParameters(keys: [(identity: String, key: Data)], peerToPeer: Bool) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        for entry in keys { addKey(entry.key, identity: entry.identity, to: tls) }
        let parameters = parameters(tls)
        parameters.includePeerToPeer = peerToPeer
        return parameters
    }

    /// Plain TCP used only for the pairing handshake, which protects itself.
    static func pairingParameters(peerToPeer: Bool = true) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = peerToPeer
        return parameters
    }

    private static func addKey(_ key: Data, identity: String, to tls: NWProtocolTLS.Options) {
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                                keyData as __DispatchData,
                                                identityData as __DispatchData)
    }

    private static func parameters(_ tls: NWProtocolTLS.Options) -> NWParameters {
        let options = tls.securityProtocolOptions
        sec_protocol_options_append_tls_ciphersuite(options,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        // Marks the traffic as real-time video, so Wi-Fi and AWDL schedule it ahead of bulk data.
        parameters.serviceClass = .interactiveVideo
        return parameters
    }
}

/// Numeric-comparison pairing, as in Bluetooth Secure Simple Pairing. Both sides run an
/// X25519 exchange; the iPad commits to its nonce before seeing the Mac's, so a
/// man-in-the-middle cannot choose values that make the six-digit codes match.
struct PairStart: Codable { let macID: String; let macName: String; let publicKey: Data }
struct PairCommit: Codable { let iPadID: String; let iPadName: String; let publicKey: Data; let commitment: Data }
struct PairNonce: Codable { let nonce: Data }
struct PairSealedKey: Codable { let sealed: Data }

enum PairingCrypto {
    static func nonce() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    static func commitment(iPadKey: Data, macKey: Data, iPadNonce: Data) -> Data {
        Data(SHA256.hash(data: iPadKey + macKey + iPadNonce))
    }

    static func code(macKey: Data, iPadKey: Data, macNonce: Data, iPadNonce: Data) -> String {
        let digest = Array(SHA256.hash(data: Data("wiredpad-code".utf8) + macKey + iPadKey + macNonce + iPadNonce))
        let value = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        let digits = String(format: "%06u", value)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    static func sealingKey(shared: SharedSecret, macNonce: Data, iPadNonce: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: macNonce + iPadNonce,
                                       sharedInfo: Data("wiredpad-pair-v1".utf8), outputByteCount: 32)
    }
}
