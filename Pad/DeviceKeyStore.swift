import Foundation
import LocalAuthentication
import Security

/// P-256 keys made in the Secure Enclave, one per Mac and purpose, made when the Mac sets them
/// up. The private keys never leave it,
/// and every signature needs Touch ID or Face ID with the fingers or face enrolled when the key
/// was made; changing the enrollment makes the key unusable.
enum DeviceKeyStore {
    private static func tag(_ purpose: SigningPurpose, mac: String) -> Data {
        Data("WiredPad.signing.\(mac).\(purpose.rawValue)".utf8)
    }

    /// Makes new keys for `mac`, replacing any it had, after the user confirms with Touch ID or
    /// Face ID. Blocks while the prompt is up, so it is called off the main thread.
    static func setUp(mac: String, reason: String) throws -> [SigningPurpose: Data] {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw error ?? NSError(domain: "WiredPad.signing", code: 3)
        }
        let confirmed = DispatchSemaphore(value: 0)
        var failure: Error?
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, error in
            if !ok { failure = error ?? NSError(domain: "WiredPad.signing", code: 4) }
            confirmed.signal()
        }
        confirmed.wait()
        if let failure { throw failure }
        var keys: [SigningPurpose: Data] = [:]
        for purpose in SigningPurpose.allCases {
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: tag(purpose, mac: mac)] as CFDictionary)
            guard let key = makeKey(purpose, mac: mac),
                  let publicKey = SecKeyCopyPublicKey(key),
                  let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
                throw NSError(domain: "WiredPad.signing", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: L10n.tr("ipad.signing.nokey")])
            }
            keys[purpose] = data
        }
        return keys
    }

    /// Signs after asking for Touch ID or Face ID with `reason`. Blocks while the prompt is up,
    /// so it is called off the main thread.
    static func sign(_ data: Data, for purpose: SigningPurpose, mac: String, reason: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = reason
        guard let key = privateKey(purpose, mac: mac, context: context) else {
            throw NSError(domain: "WiredPad.signing", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L10n.tr("ipad.signing.nokey")])
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256,
                                                    data as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() ?? NSError(domain: "WiredPad.signing", code: 2)
        }
        return signature
    }

    private static func privateKey(_ purpose: SigningPurpose, mac: String, context: LAContext) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag(purpose, mac: mac),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item else { return nil }
        return (item as! SecKey)
    }

    private static func makeKey(_ purpose: SigningPurpose, mac: String) -> SecKey? {
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil
        ) else { return nil }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag(purpose, mac: mac),
                kSecAttrAccessControl as String: access,
            ],
        ]
        return SecKeyCreateRandomKey(attributes as CFDictionary, nil)
    }
}
