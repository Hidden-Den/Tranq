import SwiftUI

/// Содержимое вкладки «Настройки»: показывает один раздел, выбранный в боковом меню.
struct SettingsView: View {
    let section: SettingsSection
    @ObservedObject private var historyLock = HistoryLockCoordinator.shared

    var body: some View {
        switch section {
        case .dictation: DictationSettingsSection()
        case .recognition: RecognitionSettingsSection()
        case .processing: SettingsPage { VoiceIntelligenceSection() }
        case .provider: SettingsPage { AIProviderSection() }
        case .app: AppSettingsSection()
        case .data:
            // Закрытия зовут долгоживущую службу: модель настроек захватывает их один раз.
            DataSettingsSection(lockState: historyLock.state,
                                presence: historyLock.presence,
                                onEnable: { try await HistoryLockMigrator.shared.enable() },
                                onDisable: { try await HistoryLockMigrator.shared.disable() })
        }
    }
}

/// Оболочка раздела: своя прокрутка, те же отступы и фон, что были у единого экрана.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                content()
            }
            .padding(20)
        }
    }
}

struct ActiveModelStatusRow: View {
    @ObservedObject var models = ModelStore.shared

    var body: some View {
        if let active = models.model(named: models.activeModelID), !active.isBundled {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(active.name))
                        .font(.ui(.body, weight: .medium))
                        .foregroundColor(.uiInk)
                        .lineLimit(1)
                    Text("\(active.sizeMB) МБ — Apple Metal")
                        .font(.ui(.caption))
                        .foregroundColor(.uiMidGray)
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                if models.downloadingID == active.id {
                    HStack(spacing: 8) {
                        VStack(alignment: .trailing, spacing: 4) {
                            ProgressView(value: models.downloadProgress)
                                .frame(width: 170)
                            Text(LocalizedStringKey(models.downloadStatus))
                                .font(.ui(.micro))
                                .foregroundColor(.uiMidGray)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .frame(width: 170, alignment: .trailing)

                        UIOutlineButton(title: "Отмена") { models.cancel() }
                    }
                } else if models.isDownloaded(active.id) {
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.uiSuccess)
                                .frame(width: 6, height: 6)
                            Text(LocalizedStringKey("RecognitionModel.Installed"))
                                .font(.ui(.caption, weight: .medium))
                                .foregroundColor(Color.uiSuccess)
                                .lineLimit(1)
                        }
                        UIOutlineButton(title: "Удалить") { models.remove(active.id) }
                    }
                } else {
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.uiAmber)
                                .frame(width: 6, height: 6)
                            Text("Не скачана")
                                .font(.ui(.caption))
                                .foregroundColor(.uiMidGray)
                                .lineLimit(1)
                        }
                        UIOutlineButton(title: "Скачать") { models.download(active.id) }
                    }
                }
            }
            .frame(minHeight: 44)
        }
    }
}
