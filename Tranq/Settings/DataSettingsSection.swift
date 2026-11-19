import SwiftUI

/// Раздел «Данные»: доступ для нейронок, логи и стирание истории.
struct DataSettingsSection: View {
    @State private var showingClearHistoryAlert = false
    @State private var showingLogsSheet = false

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

            UICard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Стереть историю")
                            .font(.ui(.body, weight: .bold))
                            .foregroundColor(.uiEmber)
                        Text("Все диктовки удалятся с устройства безвозвратно")
                            .font(.ui(.caption))
                            .foregroundColor(.uiMidGray)
                    }
                    Spacer()
                    UIDestructiveButton(title: "Очистить") {
                        showingClearHistoryAlert = true
                    }
                }
            }
        }
        .alert("Стереть всю историю?", isPresented: $showingClearHistoryAlert) {
            Button("Отмена", role: .cancel) { }
            Button("Стереть", role: .destructive) {
                PlaybackController.shared.stopSyncedPlayback()
                DataEraser.eraseAll()
            }
        } message: { Text("Все сохраненные транскрипции будут удалены безвозвратно. Это действие нельзя отменить.") }
    }
}
