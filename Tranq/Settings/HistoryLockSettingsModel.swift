import Foundation

/// Логика переключателя «Замок истории»: какой лист показать, как отказ возвращает состояние.
/// Сам флаг модель не пишет: после успеха меняется только показанное состояние,
/// сохранённое значение обновляет миграция в `onEnable` и `onDisable`.
@MainActor
final class HistoryLockSettingsModel: ObservableObject {
    enum Sheet: String, Identifiable {
        case enable, disable
        var id: String { rawValue }
    }

    typealias Action = @MainActor () async throws -> Void

    /// Показанное состояние переключателя.
    @Published private(set) var isOn: Bool
    @Published var sheet: Sheet?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWorking = false

    private let presence: PresenceAuthorizing
    private let onEnable: Action
    private let onDisable: Action
    private let onExport: Action

    init(isOn: Bool,
         presence: PresenceAuthorizing,
         onEnable: @escaping Action = {},
         onDisable: @escaping Action = {},
         onExport: @escaping Action = {}) {
        self.isOn = isOn
        self.presence = presence
        self.onEnable = onEnable
        self.onDisable = onDisable
        self.onExport = onExport
    }

    /// Переключатель нажат: открывает лист, состояние не меняется.
    func requestToggle(to on: Bool) {
        guard !isWorking, on != isOn else { return }
        errorMessage = nil
        sheet = on ? .enable : .disable
    }

    func cancel() {
        guard !isWorking else { return }
        sheet = nil
        errorMessage = nil
    }

    /// Кнопка листа. Выключение сначала просит подтвердить личность.
    func confirm() async {
        guard !isWorking, let current = sheet else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            switch current {
            case .enable:
                try await onEnable()
                isOn = true
            case .disable:
                try await presence.authorize(reason: String(localized: "выключить замок истории"))
                try await onDisable()
                isOn = false
            }
            sheet = nil
        } catch {
            // Состояние не меняется, лист остаётся для повтора.
            errorMessage = current == .enable
                ? String(localized: "Не удалось включить")
                : String(localized: "Не удалось выключить")
        }
    }

    /// Выгрузка копии ключа: доступна при включённом замке и открытой истории.
    func canExport(in state: HistoryLockState) -> Bool {
        isOn && state == .unlocked && !isWorking
    }

    func export() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await onExport()
        } catch {
            errorMessage = String(localized: "Не удалось выгрузить")
        }
    }

    /// Сохранённый флаг изменился снаружи, например после миграции.
    func sync(to stored: Bool) {
        guard !isWorking else { return }
        isOn = stored
    }
}
