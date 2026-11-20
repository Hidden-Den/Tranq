import CryptoKit
import Foundation

/// Назначение конверта. Идёт в HKDF, поэтому конверт заметки не откроется как аудио или строка журнала.
enum HistoryCryptoPurpose: String {
    case note, audio, timings, journal
}

/// Самодостаточный конверт: версия схемы, публичный ключ эфемерной пары, нонс, шифротекст с тегом.
struct SealedEnvelope: Codable {
    let version: Int
    let ephemeralPublicKey: Data
    let nonce: Data
    let ciphertext: Data
}

enum HistoryCryptoError: Error {
    case unsupportedVersion
    case unsupportedKey
}

/// Шифрование истории: ECDH с долгим ключом, HKDF-SHA256, AES-GCM-256.
/// Запечатать может любой с публичным ключом, открыть — только владелец приватного.
enum HistoryCrypto {
    static let version = 1
    static let salt = Data("tranq.history.v1".utf8)

    /// Кривая определяется по длине публичного ключа: 32 байта — Curve25519, 65 — P-256 из Secure Enclave.
    static func seal(_ data: Data, purpose: HistoryCryptoPurpose, publicKey: Data) throws -> SealedEnvelope {
        let ephemeralPublic: Data
        let secret: SharedSecret
        switch publicKey.count {
        case 32:
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            ephemeralPublic = ephemeral.publicKey.rawRepresentation
            secret = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
        case 65:
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
            let ephemeral = P256.KeyAgreement.PrivateKey()
            ephemeralPublic = ephemeral.publicKey.x963Representation
            secret = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
        default:
            throw HistoryCryptoError.unsupportedKey
        }
        let shared = secret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        let box = try AES.GCM.seal(data, using: derive(shared, purpose: purpose))
        return SealedEnvelope(version: version,
                              ephemeralPublicKey: ephemeralPublic,
                              nonce: box.nonce.withUnsafeBytes { Data($0) },
                              ciphertext: Data(box.ciphertext) + Data(box.tag))
    }

    /// Ошибки ключа `HistoryKeyError` проходят наружу как есть; порча конверта даёт ошибку CryptoKit.
    static func open(_ envelope: SealedEnvelope, purpose: HistoryCryptoPurpose, key: HistoryKeyProviding) throws -> Data {
        guard envelope.version == version else { throw HistoryCryptoError.unsupportedVersion }
        let shared = try key.agree(withEphemeral: envelope.ephemeralPublicKey)
        let box = try AES.GCM.SealedBox(combined: envelope.nonce + envelope.ciphertext)
        return try AES.GCM.open(box, using: derive(shared, purpose: purpose))
    }

    private static func derive(_ shared: SymmetricKey, purpose: HistoryCryptoPurpose) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: shared,
                               salt: salt,
                               info: Data(purpose.rawValue.utf8),
                               outputByteCount: 32)
    }
}
