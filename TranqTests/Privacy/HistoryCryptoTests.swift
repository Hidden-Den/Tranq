//
//  HistoryCryptoTests.swift
//  TranqTests
//

import Testing
import CryptoKit
import Foundation
@testable import Tranq

/// Конверт истории: открывается своим ключом и своим назначением, порча даёт ошибку.
struct HistoryCryptoTests {

    private let sample = Data("ну это секретная заметка".utf8)

    @Test func sealedDataOpensBack() throws {
        let key = TestHistoryKey()
        for purpose in [HistoryCryptoPurpose.note, .audio, .timings, .journal] {
            let envelope = try HistoryCrypto.seal(sample, purpose: purpose, publicKey: key.publicKey)
            #expect(envelope.version == 1)
            #expect(try HistoryCrypto.open(envelope, purpose: purpose, key: key) == sample)
        }
    }

    @Test func envelopeFromAnotherPurposeDoesNotOpen() throws {
        let key = TestHistoryKey()
        let envelope = try HistoryCrypto.seal(sample, purpose: .note, publicKey: key.publicKey)
        #expect(throws: (any Error).self) {
            try HistoryCrypto.open(envelope, purpose: .journal, key: key)
        }
    }

    @Test func flippedByteFailsToOpen() throws {
        let key = TestHistoryKey()
        let envelope = try HistoryCrypto.seal(sample, purpose: .note, publicKey: key.publicKey)
        var bytes = envelope.ciphertext
        bytes[bytes.startIndex] ^= 0x01
        let broken = SealedEnvelope(version: envelope.version,
                                    ephemeralPublicKey: envelope.ephemeralPublicKey,
                                    nonce: envelope.nonce,
                                    ciphertext: bytes)
        #expect(throws: (any Error).self) {
            try HistoryCrypto.open(broken, purpose: .note, key: key)
        }
    }

    @Test func twoSealsOfSameDataDiffer() throws {
        let key = TestHistoryKey()
        let first = try HistoryCrypto.seal(sample, purpose: .note, publicKey: key.publicKey)
        let second = try HistoryCrypto.seal(sample, purpose: .note, publicKey: key.publicKey)
        #expect(first.ephemeralPublicKey != second.ephemeralPublicKey)
        #expect(first.ciphertext != second.ciphertext)
    }

    @Test func anotherKeyDoesNotOpen() throws {
        let key = TestHistoryKey()
        let envelope = try HistoryCrypto.seal(sample, purpose: .note, publicKey: key.publicKey)
        #expect(throws: (any Error).self) {
            try HistoryCrypto.open(envelope, purpose: .note, key: TestHistoryKey())
        }
    }

    @Test func keyFailureComesThroughOpen() throws {
        let key = TestHistoryKey()
        let envelope = try HistoryCrypto.seal(sample, purpose: .note, publicKey: key.publicKey)
        key.failure = .denied
        #expect(throws: HistoryKeyError.denied) {
            try HistoryCrypto.open(envelope, purpose: .note, key: key)
        }
    }

    /// Путь Secure Enclave: та же схема на P-256, проверенная ключом в памяти.
    @Test func p256KeyOpensBack() throws {
        let key = P256TestKey()
        let envelope = try HistoryCrypto.seal(sample, purpose: .audio, publicKey: key.publicKey)
        #expect(envelope.ephemeralPublicKey.count == 65)
        #expect(try HistoryCrypto.open(envelope, purpose: .audio, key: key) == sample)
    }
}

private struct P256TestKey: HistoryKeyProviding {
    let privateKey = P256.KeyAgreement.PrivateKey()
    var exists: Bool { true }
    var publicKey: Data { privateKey.publicKey.x963Representation }
    func agree(withEphemeral ephemeral: Data) throws -> SymmetricKey {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: ephemeral)
        return try privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { SymmetricKey(data: Data($0)) }
    }
    func create() throws {}
    func destroy() throws {}
}
