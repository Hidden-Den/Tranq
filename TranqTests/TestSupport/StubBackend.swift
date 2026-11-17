import Foundation
@testable import Tranq

/// Подмена модели в тестах: возвращает заданный ответ или бросает заданную ошибку и считает вызовы.
final class StubBackend: CleanupBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var received: String?
    private let reply: String?
    private let error: CleanupBackendError?

    init(reply: String) {
        self.reply = reply
        self.error = nil
    }

    init(error: CleanupBackendError) {
        self.reply = nil
        self.error = error
    }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// Текст, который пришёл в последнем вызове.
    var lastUser: String? {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        lock.lock()
        count += 1
        received = user
        lock.unlock()
        if let error { throw error }
        return reply ?? ""
    }
}
