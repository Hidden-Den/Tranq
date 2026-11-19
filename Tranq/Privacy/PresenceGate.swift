import Foundation
import LocalAuthentication

/// Подтверждение личности перед чтением истории.
protocol PresenceAuthorizing {
    /// Бросает `HistoryKeyError.denied` на любую неудачу: отказ, отмену, нечем подтвердить.
    func authorize(reason: String) async throws
}

/// Общий контекст подтверждения: ключ истории используется с ним без второго диалога.
/// `reset` забывает подтверждение, его зовут при запирании.
final class HistoryAuthSession {
    static let shared = HistoryAuthSession()

    /// Текст диалога, если ключ просят до явной разблокировки.
    static let defaultReason = String(localized: "открыть историю")

    private let lock = NSLock()
    private var current = LAContext()
    private var authorized = false

    var context: LAContext {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    var isAuthorized: Bool {
        lock.lock(); defer { lock.unlock() }
        return authorized
    }

    func markAuthorized(_ context: LAContext) {
        lock.lock(); defer { lock.unlock() }
        if context === current { authorized = true }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        current.invalidate()
        current = LAContext()
        authorized = false
    }

    /// Программная проверка личности для пути без Secure Enclave. Блокирует поток до ответа,
    /// диалог показывает система, поэтому зовётся и с главного потока.
    func ensureAuthorized() throws {
        if isAuthorized { return }
        let context = self.context
        let reason = context.localizedReason.isEmpty ? Self.defaultReason : context.localizedReason
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            if !success { failure = error ?? HistoryKeyError.denied }
            done.signal()
        }
        done.wait()
        if failure != nil { throw HistoryKeyError.denied }
        markAuthorized(context)
    }
}

/// Touch ID с запасным паролем Mac.
struct LocalAuthPresenceGate: PresenceAuthorizing {
    var session: HistoryAuthSession = .shared

    func authorize(reason: String) async throws {
        let context = session.context
        context.localizedReason = reason
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            session.markAuthorized(context)
        } catch {
            // Неудача проверки не значит потерю ключа: всегда отказ, история остаётся запертой.
            throw HistoryKeyError.denied
        }
    }
}
