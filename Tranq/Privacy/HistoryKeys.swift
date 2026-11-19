import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum HistoryKeyError: Error {
    /// Человек отказал или отменил подтверждение.
    case denied
    /// Ключа нет или он не читается на этом Mac.
    case unavailable
}

/// Долгий ключ согласования истории. Публичная часть читается без подтверждения,
/// `agree` требует подтверждения личности и отдаёт общий секрет с эфемерным ключом конверта.
protocol HistoryKeyProviding {
    var publicKey: Data { get throws }
    func agree(withEphemeral: Data) throws -> SymmetricKey
    func create() throws
    func destroy() throws
    var exists: Bool { get }
}

enum HistoryKeyFactory {
    /// Secure Enclave, где он есть, иначе Связка ключей.
    static func make() -> HistoryKeyProviding {
        SecureEnclave.isAvailable ? SecureEnclaveHistoryKey() : KeychainHistoryKey()
    }
}

/// P-256 в Secure Enclave: приватная часть не покидает чип, в Связке ключей лежит её представление.
struct SecureEnclaveHistoryKey: HistoryKeyProviding {
    var session: HistoryAuthSession = .shared

    private let keychain = HistoryKeychain(privateAccount: "secureEnclave.private",
                                           publicAccount: "secureEnclave.public")

    var exists: Bool { keychain.hasPublic }

    var publicKey: Data {
        get throws { try keychain.readPublic() }
    }

    func agree(withEphemeral ephemeral: Data) throws -> SymmetricKey {
        let blob = try keychain.readPrivate(context: nil)
        do {
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob,
                                                                     authenticationContext: session.context)
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: ephemeral)
            let secret = try key.sharedSecretFromKeyAgreement(with: peer)
            return secret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        } catch {
            throw HistoryKeyError.fromEnclave(error)
        }
    }

    func create() throws {
        try destroy()
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil,
                                                           kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .userPresence],
                                                           &error) else {
            throw HistoryKeyError.unavailable
        }
        let key: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        } catch {
            throw HistoryKeyError.unavailable
        }
        // Представление ключа бесполезно вне этого чипа, поэтому в Связке ключей оно без userPresence.
        try keychain.add(privateData: key.dataRepresentation, access: nil,
                         publicData: key.publicKey.x963Representation)
    }

    func destroy() throws { try keychain.deleteAll() }
}

/// Curve25519 без Secure Enclave: байты ключа в Связке ключей под userPresence.
struct KeychainHistoryKey: HistoryKeyProviding {
    var session: HistoryAuthSession = .shared

    private let keychain = HistoryKeychain(privateAccount: "curve25519.private",
                                           publicAccount: "curve25519.public")

    var exists: Bool { keychain.hasPublic }

    var publicKey: Data {
        get throws { try keychain.readPublic() }
    }

    func agree(withEphemeral ephemeral: Data) throws -> SymmetricKey {
        let raw = try keychain.readPrivate(context: session.context)
        let key: Curve25519.KeyAgreement.PrivateKey
        let peer: Curve25519.KeyAgreement.PublicKey
        do {
            key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
            peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeral)
        } catch {
            throw HistoryKeyError.unavailable
        }
        let secret = try key.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
    }

    func create() throws {
        try destroy()
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil,
                                                           kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           .userPresence,
                                                           &error) else {
            throw HistoryKeyError.unavailable
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try keychain.add(privateData: key.rawRepresentation, access: access,
                         publicData: key.publicKey.rawRepresentation)
    }

    func destroy() throws { try keychain.deleteAll() }
}

/// Два элемента Связки ключей под сервисом `nuter.Tranq.historyKey`: приватная часть и публичная.
/// Публичная лежит отдельно, чтобы запись конвертов и проверка наличия ключа шли без диалога.
private struct HistoryKeychain {
    static let service = "nuter.Tranq.historyKey"

    let privateAccount: String
    let publicAccount: String

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    var hasPublic: Bool {
        var query = base(publicAccount)
        query[kSecReturnData as String] = false
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func readPublic() throws -> Data { try read(base(publicAccount)) }

    func readPrivate(context: LAContext?) throws -> Data {
        var query = base(privateAccount)
        if let context { query[kSecUseAuthenticationContext as String] = context }
        return try read(query)
    }

    func add(privateData: Data, access: SecAccessControl?, publicData: Data) throws {
        var privateItem = base(privateAccount)
        privateItem[kSecValueData as String] = privateData
        if let access {
            privateItem[kSecAttrAccessControl as String] = access
        } else {
            privateItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        var publicItem = base(publicAccount)
        publicItem[kSecValueData as String] = publicData
        publicItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        try check(SecItemAdd(privateItem as CFDictionary, nil))
        do {
            try check(SecItemAdd(publicItem as CFDictionary, nil))
        } catch {
            try? deleteAll()
            throw error
        }
    }

    func deleteAll() throws {
        for account in [privateAccount, publicAccount] {
            let status = SecItemDelete(base(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw HistoryKeyError.unavailable
            }
        }
    }

    private func read(_ query: [String: Any]) throws -> Data {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        try check(SecItemCopyMatching(query as CFDictionary, &result))
        guard let data = result as? Data else { throw HistoryKeyError.unavailable }
        return data
    }

    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: throw HistoryKeyError.denied
        default: throw HistoryKeyError.unavailable
        }
    }
}

extension HistoryKeyError {
    /// Отказ в Secure Enclave приходит ошибкой LocalAuthentication, иногда вложенной.
    static func fromEnclave(_ error: Error) -> HistoryKeyError {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == LAError.errorDomain { return from(authError: nsError) }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .unavailable
    }
}
