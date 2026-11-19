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

    // MARK: - Файлы ключа Secure Enclave, без самого Secure Enclave

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tranq-history-key-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func keyFilesAreOwnerOnly() throws {
        let url = makeDirectory().appendingPathComponent(HistoryKeyFiles.publicFileName)
        try HistoryKeyFiles.write(sample, to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try HistoryKeyFiles.read(url) == sample)
    }

    @Test func enclaveKeyExistsFollowsFilesAndDestroyRemovesThem() throws {
        let dir = makeDirectory()
        let key = SecureEnclaveHistoryKey(directory: dir)
        #expect(!key.exists)
        let publicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        try HistoryKeyFiles.write(Data("заглушка".utf8), to: dir.appendingPathComponent(SecureEnclaveHistoryKey.blobFileName))
        try HistoryKeyFiles.write(publicKey, to: dir.appendingPathComponent(HistoryKeyFiles.publicFileName))
        #expect(key.exists)
        #expect(try key.publicKey == publicKey)

        try key.destroy()
        #expect(!key.exists)
        #expect(throws: HistoryKeyError.unavailable) { try key.publicKey }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(HistoryKeyFiles.publicFileName).path))
    }

    @Test func missingEnclaveBlobIsUnavailable() throws {
        let key = SecureEnclaveHistoryKey(directory: makeDirectory())
        let ephemeral = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        #expect(throws: HistoryKeyError.unavailable) {
            try key.agree(withEphemeral: ephemeral)
        }
    }

    // MARK: - Порядок записи и удаления пары

    private struct WriteFailure: Error {}

    @Test func failedPrivateWriteLeavesNoPublicFile() throws {
        let pub = makeDirectory().appendingPathComponent(HistoryKeyFiles.publicFileName)
        #expect(throws: WriteFailure.self) {
            try HistoryKeyFiles.installPair(publicKey: sample, at: pub,
                                            writePrivate: { throw WriteFailure() },
                                            removePrivate: {})
        }
        #expect(!FileManager.default.fileExists(atPath: pub.path))
    }

    @Test func failedPublicWriteRollsBackPrivate() throws {
        let dir = makeDirectory()
        let blob = dir.appendingPathComponent(SecureEnclaveHistoryKey.blobFileName)
        let pub = dir.appendingPathComponent(HistoryKeyFiles.publicFileName)
        // На месте публичного файла непустая папка: переименование в неё не пройдёт.
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: pub.appendingPathComponent("busy"))

        #expect(throws: (any Error).self) {
            try HistoryKeyFiles.installPair(publicKey: sample, at: pub,
                                            writePrivate: { try HistoryKeyFiles.write(Data("заглушка".utf8), to: blob) },
                                            removePrivate: { _ = try? HistoryKeyFiles.remove(blob) })
        }
        #expect(!FileManager.default.fileExists(atPath: blob.path))
        #expect(!SecureEnclaveHistoryKey(directory: dir).exists)
    }

    @Test func destroyRemovesPublicBeforePrivate() throws {
        let dir = makeDirectory()
        let pub = dir.appendingPathComponent(HistoryKeyFiles.publicFileName)
        try HistoryKeyFiles.write(sample, to: pub)
        var publicGoneFirst = false
        #expect(throws: WriteFailure.self) {
            try HistoryKeyFiles.removePair(publicAt: pub) {
                publicGoneFirst = !FileManager.default.fileExists(atPath: pub.path)
                throw WriteFailure()
            }
        }
        #expect(publicGoneFirst)
    }

    @Test func publicKeyThrowsWithoutPrivatePart() throws {
        let dir = makeDirectory()
        try HistoryKeyFiles.write(sample, to: dir.appendingPathComponent(HistoryKeyFiles.publicFileName))
        let key = SecureEnclaveHistoryKey(directory: dir)
        #expect(!key.exists)
        #expect(throws: HistoryKeyError.unavailable) { try key.publicKey }
    }

    // MARK: - Разовая проверка личности, через подставную проверку

    /// Проверка отвечает с задержкой с чужого потока и считает вызовы.
    private final class SlowEvaluator {
        private let lock = NSLock()
        private var count = 0
        let answer: Bool
        init(answer: Bool) { self.answer = answer }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func evaluate(_ reason: String, _ completion: @escaping (Bool) -> Void) {
            lock.lock(); count += 1; lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { completion(self.answer) }
        }
    }

    @Test func concurrentCallersShareOneEvaluation() throws {
        let evaluator = SlowEvaluator(answer: true)
        let session = HistoryAuthSession(evaluator: evaluator.evaluate)
        let lock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            do { try session.ensureAuthorized() } catch { lock.lock(); failures += 1; lock.unlock() }
        }
        #expect(evaluator.calls == 1)
        #expect(failures == 0)
        #expect(session.isAuthorized)
        try session.ensureAuthorized()
        #expect(evaluator.calls == 1)
    }

    @Test func deniedEvaluationIsSharedAndRetriedLater() throws {
        let evaluator = SlowEvaluator(answer: false)
        let session = HistoryAuthSession(evaluator: evaluator.evaluate)
        let lock = NSLock()
        var denials = 0
        DispatchQueue.concurrentPerform(iterations: 3) { _ in
            do { try session.ensureAuthorized() } catch HistoryKeyError.denied {
                lock.lock(); denials += 1; lock.unlock()
            } catch {}
        }
        #expect(evaluator.calls == 1)
        #expect(denials == 3)
        #expect(!session.isAuthorized)
        #expect(throws: HistoryKeyError.denied) { try session.ensureAuthorized() }
        #expect(evaluator.calls == 2)
    }

    @Test func resetForgetsAuthorization() throws {
        let evaluator = SlowEvaluator(answer: true)
        let session = HistoryAuthSession(evaluator: evaluator.evaluate)
        try session.ensureAuthorized()
        session.reset()
        #expect(!session.isAuthorized)
        try session.ensureAuthorized()
        #expect(evaluator.calls == 2)
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
