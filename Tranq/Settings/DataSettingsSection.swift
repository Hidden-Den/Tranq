import SwiftUI

/// Раздел «Данные»: доступ для нейронок, логи, замок и стирание истории.
struct DataSettingsSection: View {
    @State private var showingClearHistoryAlert = false
    @State private var showingLogsSheet = false
    @StateObject private var lockModel: HistoryLockSettingsModel
    @ObservedObject private var preferences = AppPreferences.shared
    /// Состояние замка: выгрузка доступна только при открытой истории.
    private let lockState: HistoryLockState
    /// Находка уборки при запуске: строка в карточке замка до ухода из раздела.
    private let launchNotice: HistoryMigration.LaunchNotice?
    private let onNoticeSeen: () -> Void
    private let onErase: () -> Void
    /// Последнее стирание убрало не всё.
    private let eraseFailed: Bool

    /// `onEnable` и `onDisable` делают миграцию и пишут флаг, `onExport` — выгрузку,
    /// `onErase` стирает историю и при включённом замке заводит новый ключ.
    init(lockState: HistoryLockState = .off,
         presence: PresenceAuthorizing = LocalAuthPresenceGate(),
         launchNotice: HistoryMigration.LaunchNotice? = nil,
         eraseFailed: Bool = false,
         onNoticeSeen: @escaping () -> Void = {},
         onEnable: @escaping HistoryLockSettingsModel.Action = {},
         onDisable: @escaping HistoryLockSettingsModel.Action = {},
         onExport: @escaping HistoryLockSettingsModel.Action = {},
         onErase: @escaping () -> Void = {}) {
        self.lockState = lockState
        self.launchNotice = launchNotice
        self.onNoticeSeen = onNoticeSeen
        self.onErase = onErase
        self.eraseFailed = eraseFailed
        _lockModel = StateObject(wrappedValue: HistoryLockSettingsModel(
            isOn: AppPreferences.historyLockEnabled(in: AppEnvironment.defaults),
            presence: presence, onEnable: onEnable, onDisable: onDisable, onExport: onExport))
    }

    var body: some View {
        SettingsPage {
            MCPSettingsSection()

            UICard {
                HStack {
                    Text("Логи приложения")
                        .font(.ui(.body, weight: .medium))
                        .foregroundColor(.uiInk)
                    Spacer()
                    UIOutlineButton(title: "Открыть") {
                        showingLogsSheet = true
                    }
                }
                .sheet(isPresented: $showingLogsSheet) {
                    LogsView()
                }
            }

            HistoryLockCard(model: lockModel, lockState: lockState, notice: launchNotice)
                .onDisappear { if launchNotice != nil { onNoticeSeen() } }

            UICard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Стереть историю")
                            .font(.ui(.body, weight: .bold))
                            .foregroundColor(.uiEmber)
                        Text("Все диктовки удалятся с устройства безвозвратно")
                            .font(.ui(.caption))
                            .foregroundColor(.uiMidGray)
                        if eraseFailed {
                            Text("Не всё удалось стереть")
                                .font(.ui(.caption))
                                .foregroundColor(.uiEmber)
                        }
                    }
                    Spacer()
                    UIDestructiveButton(title: "Очистить") {
                        showingClearHistoryAlert = true
                    }
                }
            }
        }
        .onChange(of: preferences.historyLockEnabled) { stored in
            lockModel.sync(to: stored)
        }
        .alert("Стереть всю историю?", isPresented: $showingClearHistoryAlert) {
            Button("Отмена", role: .cancel) { }
            Button("Стереть", role: .destructive) {
                PlaybackController.shared.stopSyncedPlayback()
                onErase()
            }
        } message: { Text("Все сохраненные транскрипции будут удалены безвозвратно. Это действие нельзя отменить.") }
    }
}

/// Карточка «Замок истории»: переключатель, ключ и выгрузка.
private struct HistoryLockCard: View {
    @ObservedObject var model: HistoryLockSettingsModel
    let lockState: HistoryLockState
    let notice: HistoryMigration.LaunchNotice?

    var body: some View {
        UICard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Замок истории")
                            .font(.ui(.body, weight: .medium))
                            .foregroundColor(.uiInk)
                        Text("Требовать Touch ID")
                            .font(.ui(.caption))
                            .foregroundColor(.uiMidGray)
                        if let notice {
                            Text(notice.text)
                                .font(.ui(.caption))
                                .foregroundColor(.uiEmber)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.isOn },
                        set: { model.requestToggle(to: $0) }))
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
                        .disabled(model.isWorking)
                }

                if model.isOn {
                    Divider().background(Color.uiHairline)

                    HStack {
                        Text("Ключ хранится на этом Mac")
                            .font(.ui(.caption))
                            .foregroundColor(.uiMidGray)
                        Spacer()
                        UIOutlineButton(title: "Выгрузить") {
                            Task { await model.export() }
                        }
                        .disabled(!model.canExport(in: lockState))
                        .opacity(model.canExport(in: lockState) ? 1 : 0.4)
                    }
                }

                if model.sheet == nil, let message = model.errorMessage {
                    Text(message)
                        .font(.ui(.caption))
                        .foregroundColor(.uiEmber)
                }
            }
        }
        .sheet(item: $model.sheet) { sheet in
            HistoryLockSheet(model: model, sheet: sheet)
        }
    }
}

/// Лист подтверждения включения или выключения замка.
private struct HistoryLockSheet: View {
    @ObservedObject var model: HistoryLockSettingsModel
    let sheet: HistoryLockSettingsModel.Sheet

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch sheet {
            case .enable:
                Text("Включить замок")
                    .font(.ui(.headline, weight: .bold))
                    .foregroundColor(.uiInk)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ключ привязан к этому Mac.")
                    Text("На другом Mac история не прочитается.")
                    Text("Копию можно сохранить заранее.")
                    Text("Вернуть её в Tranq пока нельзя.")
                    Text("Логи приложения будут очищены.")
                }
                .font(.ui(.body))
                .foregroundColor(.uiMidGray)
            case .disable:
                Text("Выключить замок")
                    .font(.ui(.headline, weight: .bold))
                    .foregroundColor(.uiInk)
                Text("История снова будет доступна без подтверждения")
                    .font(.ui(.body))
                    .foregroundColor(.uiMidGray)
            }

            if let message = model.errorMessage {
                Text(message)
                    .font(.ui(.caption))
                    .foregroundColor(.uiEmber)
            }

            HStack {
                Spacer()
                UIOutlineButton(title: "Отмена") { model.cancel() }
                    .disabled(model.isWorking)
                UIPrimaryButton(title: sheet == .enable ? "Включить" : "Выключить") {
                    Task { await model.confirm() }
                }
                .disabled(model.isWorking)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
