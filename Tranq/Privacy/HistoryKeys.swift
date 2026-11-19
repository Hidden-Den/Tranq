import CryptoKit
import Darwin
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

/// P-256 в Secure Enclave: приватная часть не покидает чип, её непрозрачное представление
/// лежит файлом `history-key.se`, публичный ключ — файлом `history-key.pub`.
/// Связка ключей не используется: без Team ID она отвечает -34018.
struct SecureEnclaveHistoryKey: HistoryKeyProviding {
    static let blobFileName = "history-key.se"

    var directory: URL = AppEnvironment.dataDirectory
    var session: HistoryAuthSession = .shared

    private var blobURL: URL { directory.appendingPathComponent(Self.blobFileName) }
    private var publicURL: URL { directory.appendingPathComponent(HistoryKeyFiles.publicFileName) }

    var exists: Bool { FileManager.default.fileExists(atPath: blobURL.path) }

    var publicKey: Data {
        get throws { try HistoryKeyFiles.read(publicURL) }
    }

    func agree(withEphemeral ephemeral: Data) throws -> SymmetricKey {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: ephemeral)
        let blob = try HistoryKeyFiles.read(blobURL)
        let key: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob,
                                                                 authenticationContext: session.context)
        } catch {
            throw HistoryKeyError.unavailable
        }
        do {
            let secret = try key.sharedSecretFromKeyAgreement(with: peer)
            return secret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        } catch {
            // Ключ на месте: любая ошибка здесь считается отказом, а не потерей ключа.
            throw HistoryKeyError.denied
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
        try HistoryKeyFiles.write(key.publicKey.x963Representation, to: publicURL)
        try HistoryKeyFiles.write(key.dataRepresentation, to: blobURL)
    }

    func destroy() throws {
        try HistoryKeyFiles.remove(blobURL)
        try HistoryKeyFiles.remove(publicURL)
    }
}

/// Curve25519 для Mac без Secure Enclave.
/// Защита этого пути — пароль входа на связке ключей login и программная проверка личности
/// перед согласованием, одна на разлочку, — не железо. Без Team ID защищённые элементы Связки ключей недоступны.
struct KeychainHistoryKey: HistoryKeyProviding {
    static let service = "nuter.Tranq.historyKey"
    static let account = "curve25519.private"

    var directory: URL = AppEnvironment.dataDirectory
    var session: HistoryAuthSession = .shared

    private var publicURL: URL { directory.appendingPathComponent(HistoryKeyFiles.publicFileName) }

    private var itemQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    var exists: Bool {
        SecItemCopyMatching(itemQuery as CFDictionary, nil) == errSecSuccess
    }

    var publicKey: Data {
        get throws { try HistoryKeyFiles.read(publicURL) }
    }

    func agree(withEphemeral ephemeral: Data) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeral)
        try session.ensureAuthorized()

        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw HistoryKeyError.unavailable }
        guard status == errSecSuccess, let raw = result as? Data else { throw HistoryKeyError.denied }

        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
            throw HistoryKeyError.unavailable
        }
        do {
            let secret = try key.sharedSecretFromKeyAgreement(with: peer)
            return secret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        } catch {
            throw HistoryKeyError.denied
        }
    }

    func create() throws {
        try destroy()
        let key = Curve25519.KeyAgreement.PrivateKey()
        var item = itemQuery
        item[kSecValueData as String] = key.rawRepresentation
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw HistoryKeyError.unavailable }
        do {
            try HistoryKeyFiles.write(key.publicKey.rawRepresentation, to: publicURL)
        } catch {
            try? destroy()
            throw error
        }
    }

    func destroy() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HistoryKeyError.unavailable }
        try HistoryKeyFiles.remove(publicURL)
    }
}

/// Файлы ключа истории: запись атомарная, права 0600 с момента создания.
enum HistoryKeyFiles {
    static let publicFileName = "history-key.pub"

    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw HistoryKeyError.unavailable
        }
        guard rename(temp.path, url.path) == 0 else {
            try? fm.removeItem(at: temp)
            throw HistoryKeyError.unavailable
        }
    }

    /// Нет файла или он не читается — ключ недоступен.
    static func read(_ url: URL) throws -> Data {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw HistoryKeyError.unavailable }
        return data
    }

    static func remove(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }
}
