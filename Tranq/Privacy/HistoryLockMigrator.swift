import Foundation

/// Долгоживущая служба переключателя «Замок истории»: миграция данных, затем флаг.
/// Настройки держат свои закрытия один раз, поэтому зовут `shared`, а не захватывают состояние.
@MainActor
final class HistoryLockMigrator {
    static let shared = HistoryLockMigrator(
        coordinator: .shared,
        store: .shared,
        journal: .shared,
        directory: AppEnvironment.dataDirectory,
        setFlag: { AppPreferences.shared.historyLockEnabled = $0 }
    )

    private let store: HistoryStore
    private let journal: TranscriptJournal
    private let vault: HistoryVault
    /// Переключает хранилище и журнал. `nil` — как в координаторе, без него.
    private let switchLock: (@MainActor (Bool) -> Void)?
    private let setFlag: @MainActor (Bool) -> Void
    private var isRunning = false

    init(store: HistoryStore,
         journal: TranscriptJournal,
         vault: HistoryVault,
         switchLock: (@MainActor (Bool) -> Void)? = nil,
         setFlag: @escaping @MainActor (Bool) -> Void) {
        self.store = store
        self.journal = journal
        self.vault = vault
        self.switchLock = switchLock
        self.setFlag = setFlag
    }

    /// Переключение идёт через координатор: он держит замок, хранилище конвертов и журнал.
    convenience init(coordinator: HistoryLockCoordinator,
                     store: HistoryStore,
                     journal: TranscriptJournal,
                     directory: URL,
                     setFlag: @escaping @MainActor (Bool) -> Void) {
        self.init(store: store, journal: journal,
                  vault: HistoryVault(directory: directory, key: coordinator.key),
                  switchLock: { [weak coordinator] enabled in coordinator?.setEnabled(enabled) },
                  setFlag: setFlag)
    }

    /// Включает замок. Флаг пишется только после успеха всей миграции, при ошибке он прежний.
    func enable() async throws {
        try await exclusive {
            try await HistoryMigration.enable(store: store, journal: journal, vault: vault,
                                              activate: switchLock.map { action in { action(true) } },
                                              setFlag: setFlag)
        }
    }

    /// Выключает замок. Подтверждение личности уже спросил лист настроек.
    func disable() async throws {
        try await exclusive {
            try await HistoryMigration.disable(store: store, journal: journal, vault: vault,
                                               deactivate: switchLock.map { action in { action(false) } },
                                               setFlag: setFlag)
        }
    }

    /// Две миграции разом не идут.
    private func exclusive(_ work: () async throws -> Void) async throws {
        guard !isRunning else { throw HistoryMigrationError.busy }
        isRunning = true
        defer { isRunning = false }
        try await work()
    }
}
