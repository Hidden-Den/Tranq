import Foundation
import LocalAuthentication

/// Подтверждение личности перед чтением истории.
protocol PresenceAuthorizing {
    /// Бросает `HistoryKeyError.denied` на отказ или отмену, `.unavailable`, если подтвердить нечем.
    func authorize(reason: String) async throws
}

/// Общий контекст подтверждения: ключ истории читается с ним без второго диалога.
/// `reset` забывает подтверждение, его зовут при запирании.
final class HistoryAuthSession {
    static let shared = HistoryAuthSession()

    private let lock = NSLock()
    private var current = LAContext()

    var context: LAContext {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        current.invalidate()
        current = LAContext()
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
        } catch {
            throw HistoryKeyError.from(authError: error)
        }
    }
}

extension HistoryKeyError {
    /// Отказ и отмена — `denied`, всё остальное — `unavailable`.
    static func from(authError error: Error) -> HistoryKeyError {
        let nsError = error as NSError
        guard nsError.domain == LAError.errorDomain else { return .unavailable }
        switch LAError.Code(rawValue: nsError.code) {
        case .userCancel, .appCancel, .systemCancel, .authenticationFailed, .userFallback, .notInteractive:
            return .denied
        default:
            return .unavailable
        }
    }
}
