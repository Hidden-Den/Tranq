import Combine
import Foundation

/// Правила замка истории. Системные уведомления и таймер живут в приложении
/// и зовут чистые входы: `noteWindowVisibility`, `noteSystemWillSleep`, `noteSystemDidWake`, `tick`.
@MainActor
final class HistoryLock: ObservableObject {
    /// Сколько окно может быть скрыто до запирания.
    static let idleTimeout: TimeInterval = 15 * 60

    @Published private(set) var state: HistoryLockState

    /// Забыть подтверждение личности при запирании. Подменяется в тестах.
    var resetSession: () -> Void = { HistoryAuthSession.shared.reset() }

    private let key: HistoryKeyProviding
    private let presence: PresenceAuthorizing
    private let now: () -> Date

    private var windowOnScreen = false
    /// С какого момента окно скрыто при открытой истории.
    private var hiddenSince: Date?
    /// Идущая попытка: одновременные разлочки ждут её.
    private var attempt: Task<Void, Never>?
    /// Растёт при каждом запирании: ответ старой попытки не открывает историю.
    private var generation = 0

    init(enabled: Bool, key: HistoryKeyProviding, presence: PresenceAuthorizing,
         now: @escaping () -> Date = Date.init) {
        // Ключа нет или он не читается: сразу экран «не читается», а не вечное «заперто».
        if !enabled {
            self.state = .off
        } else {
            self.state = Self.keyReadable(key) ? .locked : .keyUnavailable
        }
        self.key = key
        self.presence = presence
        self.now = now
    }

    /// Подтверждение личности, затем проверка ключа вне главного потока.
    /// Отказ оставляет историю запертой, потеря ключа даёт `keyUnavailable`.
    func unlock() async {
        if let attempt { return await attempt.value }
        switch state {
        case .off, .unlocked:
            return
        case .keyUnavailable where !key.exists:
            return
        case .locked, .keyUnavailable:
            break
        }
        let started = generation
        let task = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.run(started: started)
            if self.generation == started { self.finish(outcome) }
            self.attempt = nil
        }
        attempt = task
        await task.value
    }

    func noteWindowVisibility(_ onScreen: Bool) {
        guard onScreen != windowOnScreen else { return }
        windowOnScreen = onScreen
        hiddenSince = onScreen ? nil : now()
    }

    /// Mac засыпает: запереть сразу.
    func noteSystemWillSleep() { lock() }

    /// Mac проснулся: запереть, если сон прошёл мимо `noteSystemWillSleep`.
    func noteSystemDidWake() { lock() }

    /// Зовётся приложением раз в несколько секунд.
    func tick() {
        guard state == .unlocked, !windowOnScreen, let hiddenSince else { return }
        if now().timeIntervalSince(hiddenSince) >= Self.idleTimeout { lock() }
    }

    /// Хранилище не прочитало конверты после разлочки и само сбросилось: замок идёт за ним,
    /// чтобы экран не показывал открытую историю над пустым списком.
    func noteStoreDowngrade(to storeState: HistoryLockState) {
        guard state == .unlocked, storeState.hidesHistory else { return }
        generation += 1
        resetSession()
        state = storeState
    }

    private enum Outcome { case unlocked, locked, keyUnavailable }

    private func run(started: Int) async -> Outcome {
        guard key.exists else { return .keyUnavailable }
        do {
            try await presence.authorize(reason: HistoryAuthSession.defaultReason)
            guard generation == started else { return .locked }
            let key = self.key
            try await Task.detached(priority: .userInitiated) { try Self.probe(key) }.value
            return .unlocked
        } catch HistoryKeyError.unavailable {
            return .keyUnavailable
        } catch {
            // Отказ и непонятные ошибки оставляют запертой: ложная потеря ключа предложила бы стереть историю.
            return .locked
        }
    }

    private func finish(_ outcome: Outcome) {
        switch outcome {
        case .unlocked:
            if !windowOnScreen { hiddenSince = now() }
            state = .unlocked
        case .locked:
            state = .locked
        case .keyUnavailable:
            state = .keyUnavailable
        }
    }

    /// Ключ на месте и его публичная часть читается. Без подтверждения личности.
    private static func keyReadable(_ key: HistoryKeyProviding) -> Bool {
        guard key.exists else { return false }
        return (try? key.publicKey) != nil
    }

    /// Ключ открывает: запечатать байт и открыть обратно.
    private nonisolated static func probe(_ key: HistoryKeyProviding) throws {
        let envelope = try HistoryCrypto.seal(Data([0]), purpose: .note, publicKey: key.publicKey)
        _ = try HistoryCrypto.open(envelope, purpose: .note, key: key)
    }

    private func lock() {
        guard state != .off else { return }
        generation += 1
        resetSession()
        if state == .unlocked { state = .locked }
    }
}
