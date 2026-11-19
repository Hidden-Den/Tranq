import Foundation
import LocalAuthentication

/// Подтверждение личности перед чтением истории.
protocol PresenceAuthorizing {
    /// Бросает `HistoryKeyError.denied` на любую неудачу: отказ, отмену, нечем подтвердить.
    func authorize(reason: String) async throws
}

/// Общий контекст подтверждения: ключ истории используется с ним без второго диалога.
/// `reset` забывает подтверждение, его зовут при запирании.
///
/// Порядок для вызывающих: сначала `PresenceAuthorizing.authorize`, потом `HistoryCrypto.open`,
/// тогда `agree` диалога не показывает. `open` и `agree` зовут вне главного потока.
final class HistoryAuthSession {
    static let shared = HistoryAuthSession()

    /// Текст диалога, если ключ просят до явной разблокировки.
    static let defaultReason = String(localized: "открыть историю")

    /// Проверка личности: текст диалога и ответ «подтверждено».
    typealias Evaluator = (_ reason: String, _ completion: @escaping (Bool) -> Void) -> Void

    /// Одна идущая проверка, её ответ делят все ждущие.
    private final class Flight {
        let done = DispatchGroup()
        var success = false
    }

    private let lock = NSLock()
    private let evaluator: Evaluator?
    private var current: LAContext?
    private var authorized = false
    private var flight: Flight?
    private var generation = 0

    /// `evaluator` подменяется в тестах; по умолчанию — `deviceOwnerAuthentication` на общем контексте.
    init(evaluator: Evaluator? = nil) {
        self.evaluator = evaluator
    }

    var context: LAContext {
        lock.lock(); defer { lock.unlock() }
        if let current { return current }
        let created = LAContext()
        current = created
        return created
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
        current?.invalidate()
        current = nil
        authorized = false
        flight = nil
        generation += 1
    }

    /// Программная проверка личности для пути без Secure Enclave.
    /// Блокирует поток до ответа: с главного потока не звать, он замрёт на всё время диалога.
    /// Одновременные вызовы ждут одну проверку и получают её ответ.
    func ensureAuthorized() throws {
        lock.lock()
        if authorized { lock.unlock(); return }
        if let running = flight {
            lock.unlock()
            running.done.wait()
            if !running.success { throw HistoryKeyError.denied }
            return
        }
        let started = Flight()
        started.done.enter()
        flight = started
        let startedGeneration = generation
        lock.unlock()

        evaluate(reason: Self.defaultReason) { success in
            self.lock.lock()
            started.success = success
            if success && startedGeneration == self.generation { self.authorized = true }
            if self.flight === started { self.flight = nil }
            self.lock.unlock()
            started.done.leave()
        }
        started.done.wait()
        if !started.success { throw HistoryKeyError.denied }
    }

    private func evaluate(reason: String, completion: @escaping (Bool) -> Void) {
        if let evaluator { return evaluator(reason, completion) }
        let context = self.context
        let text = context.localizedReason.isEmpty ? reason : context.localizedReason
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: text) { success, _ in
            completion(success)
        }
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
