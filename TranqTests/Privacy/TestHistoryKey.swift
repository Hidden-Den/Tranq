//
//  TestHistoryKey.swift
//  TranqTests
//

import CryptoKit
import Foundation
@testable import Tranq

/// Подставной ключ истории: Curve25519 в памяти, без Связки ключей и без диалогов.
/// `failure` заставляет `agree` и `publicKey` бросать заданную ошибку.
final class TestHistoryKey: HistoryKeyProviding {
    private(set) var privateKey: Curve25519.KeyAgreement.PrivateKey?
    var failure: HistoryKeyError?
    /// Сколько раз ключ согласовывался: для проверок «подтверждение один раз».
    private(set) var agreeCount = 0

    init(created: Bool = true) {
        if created { privateKey = Curve25519.KeyAgreement.PrivateKey() }
    }

    var exists: Bool { privateKey != nil }

    var publicKey: Data {
        get throws {
            if let failure { throw failure }
            guard let privateKey else { throw HistoryKeyError.unavailable }
            return privateKey.publicKey.rawRepresentation
        }
    }

    func agree(withEphemeral ephemeral: Data) throws -> SymmetricKey {
        agreeCount += 1
        if let failure { throw failure }
        guard let privateKey else { throw HistoryKeyError.unavailable }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeral)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
    }

    func create() throws {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    func destroy() throws {
        privateKey = nil
    }
}
