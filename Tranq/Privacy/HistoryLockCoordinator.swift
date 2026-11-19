import Combine
import Foundation

/// Одна точка замка истории в приложении: держит `HistoryLock`, ключ, подтверждение личности
/// и хранилище конвертов, прокидывает состояние замка в `HistoryStore` и журнал.
///
/// Правило: состояние задаёт `HistoryLock`. Хранилище, которое не прочитало конверты
/// после разлочки, сообщает об этом через `noteStoreDowngrade`, и замок идёт за ним.
/// Системные события приходят от `HistoryLockSystemMonitor`.
@MainActor
final class HistoryLockCoordinator: ObservableObject {
    static let shared: HistoryLockCoordinator = {
        // Хранилище первым: его создание доводит прерванную миграцию и может поменять флаг.
        let store = HistoryStore.shared
        return HistoryLockCoordinator(
            enabled: AppPreferences.shared.historyLockEnabled,
            store: store,
            journal: .shared,
            key: HistoryKeyFactory.make(),
            presence: LocalAuthPresenceGate(),
            directory: AppEnvironment.dataDirectory
        )
    }()

    /// Состояние замка для экрана. Повторяет `lock.state`.
    @Published private(set) var state: HistoryLockState = .off

    let key: HistoryKeyProviding
    let presence: PresenceAuthorizing
    private(set) var lock: HistoryLock
    /// Хранилище конвертов, пока замок включён.
    private(set) var vault: HistoryVault?

    var isEnabled: Bool { state != .off }

    private let store: HistoryStore
    private let journal: TranscriptJournal
    private let directory: URL
    private let erase: () -> Void
    private let resetSession: (() -> Void)?
    private let now: () -> Date
    private var windowOnScreen = false
    private var lockObserver: AnyCancellable?

    /// `resetSession` подменяет сброс подтверждения в тестах; `nil` — настоящий.
    init(enabled: Bool,
         store: HistoryStore,
         journal: TranscriptJournal,
         key: HistoryKeyProviding,
         presence: PresenceAuthorizing,
         directory: URL,
         erase: @escaping () -> Void = { DataEraser.eraseAll() },
         resetSession: (() -> Void)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.journal = journal
        self.key = key
        self.presence = presence
        self.directory = directory
        self.erase = erase
        self.resetSession = resetSession
        self.now = now
        self.lock = HistoryLock(enabled: false, key: key, presence: presence, now: now)
        // Выключенный замок при запуске ничего не трогает: журнал и хранилище как раньше.
        if enabled { install(enabled: true) } else { observe(lock) }
    }

    // MARK: - Включение

    /// Включает или выключает замок на ходу. Миграцию данных делает вызывающий:
    /// при включении — до вызова, при выключении — `history.json` пишется до вызова.
    /// Включённый замок начинает запертым.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        install(enabled: enabled)
    }

    private func install(enabled: Bool) {
        if enabled {
            // Хранилище получает конверты раньше состояния: иначе заметка не запишется.
            let vault = HistoryVault(directory: directory, key: key)
            self.vault = vault
            store.attach(vault: vault)
            journal.setSealing(.sealed(key: key))
        } else {
            journal.setSealing(.off)
        }
        let lock = HistoryLock(enabled: enabled, key: key, presence: presence, now: now)
        if let resetSession { lock.resetSession = resetSession }
        lock.noteWindowVisibility(windowOnScreen)
        self.lock = lock
        observe(lock)
        if !enabled {
            vault = nil
            store.attach(vault: nil)
        }
    }

    private func observe(_ lock: HistoryLock) {
        // Первое значение приходит сразу: хранилище встаёт в состояние замка.
        lockObserver = lock.$state.sink { [weak self] state in
            self?.apply(state)
        }
    }

    private func apply(_ newState: HistoryLockState) {
        state = newState
        guard store.lockState != newState else { return }
        if newState == .unlocked {
            store.applyLockState(.unlocked) { [weak self] in
                guard let self else { return }
                // Чтение не удалось: хранилище уже запер себя, замок идёт следом.
                self.lock.noteStoreDowngrade(to: self.store.lockState)
            }
        } else {
            store.applyLockState(newState)
        }
    }

    // MARK: - Действия экрана

    /// Только по нажатию `Разблокировать`.
    func unlock() async {
        await lock.unlock()
    }

    /// `Стереть историю` после подтверждения. Сама собой история не стирается.
    func eraseHistory() {
        erase()
    }

    // MARK: - Системные события

    func noteWindowVisibility(_ onScreen: Bool) {
        windowOnScreen = onScreen
        lock.noteWindowVisibility(onScreen)
    }

    func noteSystemWillSleep() { lock.noteSystemWillSleep() }
    func noteSystemDidWake() { lock.noteSystemDidWake() }
    func tick() { lock.tick() }
}
