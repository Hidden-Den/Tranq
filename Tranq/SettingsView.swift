import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences = AppPreferences.shared
    @ObservedObject var permissions = PermissionManager.shared
    @ObservedObject var language = LanguageSettings.shared
    @ObservedObject var theme = ThemeSettings.shared
    @ObservedObject var models = ModelStore.shared
    @ObservedObject var hotKey = HotKeySettings.shared
    @State private var showingClearHistoryAlert = false
    @State private var showingAboutSheet = false
    @State private var showingLogsSheet = false
    
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 20) {
                
                // РАЗДЕЛ 0: ЯЗЫК
                UICard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Язык приложения")
                                .font(.ui(.body, weight: .medium))
                                .foregroundColor(.uiInk)
                            Text("Приложение перезапустится автоматически")
                                .font(.ui(.caption))
                                .foregroundColor(.uiMidGray)
                        }
                        Spacer()
                        UIDropdownPicker(selection: Binding(
                            get: { language.current },
                            set: { language.select($0) }
                        ), options: [
                            .init("Система", value: AppLanguage.system),
                            .init("Русский", value: AppLanguage.ru),
                            .init("English", value: AppLanguage.en)
                        ], width: 140)
                    }
                }
                
                // РАЗДЕЛ 0.5: ЦВЕТ ИНТЕРФЕЙСА
                UICard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Цвет интерфейса")
                                .font(.ui(.body, weight: .medium))
                                .foregroundColor(.uiInk)
                            Text("Тёмная, светлая или системная тема")
                                .font(.ui(.caption))
                                .foregroundColor(.uiMidGray)
                        }
                        Spacer()
                        UIDropdownPicker(selection: Binding(
                            get: { theme.current },
                            set: { theme.select($0) }
                        ), options: [
                            .init("Система", value: AppTheme.system),
                            .init("Тёмная", value: AppTheme.dark),
                            .init("Светлая", value: AppTheme.light)
                        ], width: 140)
                    }
                }
                
                // РАЗДЕЛ 1: ОСНОВНЫЕ
                UICard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("ОСНОВНЫЕ")
                            .font(.ui(.caption, weight: .bold))
                            .tracking(1.0)
                            .foregroundColor(.uiMidGray)
                        
                        // 1. Автозапуск
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Запуск при входе")
                                    .font(.ui(.body, weight: .medium))
                                    .foregroundColor(.uiInk)
                                Text("Автоматический запуск при старте системы")
                                    .font(.ui(.caption))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()
                            Toggle("", isOn: $preferences.launchAtLoginEnabled)
                                .labelsHidden()
                                .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
                        }
                        
                        Divider().background(Color.uiHairline)
                        
                        // 2. Скрыть в Dock
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Скрыть в Dock")
                                    .font(.ui(.body, weight: .medium))
                                    .foregroundColor(.uiInk)
                                Text("Работа в фоне без значка в Dock")
                                    .font(.ui(.caption))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()
                            Toggle("Скрыть в Dock", isOn: $preferences.hideInDock)
                                .labelsHidden()
                                .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
                        }
                        
                        Divider().background(Color.uiHairline)
                        
                        // 2. Авто-вставка
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Авто-вставка текста")
                                        .font(.ui(.body, weight: .medium))
                                        .foregroundColor(.uiInk)
                                    
                                    if !permissions.isAccessibilityGranted {
                                        Text("Разрешите доступ")
                                            .font(.ui(.micro, weight: .bold))
                                            .foregroundColor(.uiWarn)
                                    }
                                }
                                
                                Text(permissions.isAccessibilityGranted ?
                                     LocalizedStringKey("Печатать расшифровку прямо в место курсора") :
                                     LocalizedStringKey("Выдайте доступ в Универсальном доступе macOS"))
                                    .font(.ui(.caption))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()
                            
                            if permissions.isAccessibilityGranted {
                                Toggle("", isOn: $preferences.autoPasteEnabled)
                                    .labelsHidden()
                                    .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
                            } else {
                                UIOutlineButton(title: "Настройки") {
                                    permissions.requestAccessibilityPermission()
                                }
                            }
                        }
                        
                        Divider().background(Color.uiHairline)
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Сразу открывать в истории")
                                    .font(.ui(.body, weight: .medium))
                                    .foregroundColor(.uiInk)
                                Text("Открывать новую запись после расшифровки")
                                    .font(.ui(.caption))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()
                            Toggle("", isOn: $preferences.autoOpenNoteEnabled)
                                .labelsHidden()
                                .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
                        }
                        
                        Divider().background(Color.uiHairline)
                        
                        // 4. Звуки
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Системные звуки")
                                    .font(.ui(.body, weight: .medium))
                                    .foregroundColor(.uiInk)
                                Text("Акустический отклик при активации, копировании и ошибках")
                                    .font(.ui(.caption))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()
                            Toggle("", isOn: $preferences.soundEnabled)
                                .labelsHidden()
                                .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
                        }
                    }
                }
                
                // РАЗДЕЛ 2: УПРАВЛЕНИЕ
                UICard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("УПРАВЛЕНИЕ")
                            .font(.ui(.caption, weight: .bold))
                            .tracking(1.0)
                            .foregroundColor(.uiMidGray)
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Горячая клавиша")
                                    .font(.ui(.body, weight: .medium))
                                    .foregroundColor(.uiInk)
                                if let warning = hotKey.warningMessage {
                                    Text(warning)
                                        .font(.ui(.caption))
                                        .foregroundColor(.uiWarn)
                                } else if hotKey.isCapturing {
                                    Text(LocalizedStringKey("HotKey.Capture"))
                                        .font(.ui(.caption))
                                        .foregroundColor(.uiMidGray)
                                } else if hotKey.isTaken {
                                    Text(LocalizedStringKey("HotKey.Taken"))
                                        .font(.ui(.caption))
                                        .foregroundColor(.uiWarn)
                                } else if !hotKey.isConfigured {
                                    Text("Клавиша не назначена")
                                        .font(.ui(.caption))
                                        .foregroundColor(.uiMidGray)
                                }
                            }
                            Spacer()
                            if hotKey.isCapturing {
                                UIBadge(text: "…")
                            } else {
                                UIBadge(text: hotKey.hotKeyName)
                            }
                            if hotKey.isConfigured && !hotKey.isCapturing {
                                UIOutlineButton(title: "Сбросить") {
                                    hotKey.clear()
                                }
                            }
                            UIOutlineButton(title: hotKey.isCapturing ? LocalizedStringKey("Отмена") : (hotKey.isConfigured ? LocalizedStringKey("Изменить") : LocalizedStringKey("Назначить"))) {
                                if hotKey.isCapturing { hotKey.endCapture() } else { hotKey.beginCapture() }
                            }
                        }
                        
                        Divider().background(Color.uiHairline)
                        
                        HStack {
                            Text("Режим диктовки")
                                .font(.ui(.body, weight: .medium))
                                .foregroundColor(.uiInk)
                            Spacer()
                            UIDropdownPicker(selection: $hotKey.mode, options: [
                                .init(LocalizedStringKey("HotKey.ModeToggle"), value: HotKeyMode.toggle),
                                .init(LocalizedStringKey("HotKey.ModePushToTalk"), value: HotKeyMode.pushToTalk)
                            ], width: 160)
                        }
                        
                        Divider().overlay(Color.uiHairline)
                        
                        HStack {
                            Text("Отмена записи")
                                .font(.ui(.body, weight: .medium))
                                .foregroundColor(.uiInk)
                            Spacer()
                            UIBadge(text: "ESC")
                        }
                    }
                }
                
                // РАЗДЕЛ 3: ДВИЖОК
                UICard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("ДВИЖОК И УСКОРЕНИЕ")
                            .font(.ui(.caption, weight: .bold))
                            .tracking(1.0)
                            .foregroundColor(.uiMidGray)
                        
HStack {
                            Text("Языковая модель")
                                .font(.ui(.body, weight: .medium))
                                .foregroundColor(.uiInk)
                            Spacer()
                            UIDropdownPicker(selection: Binding(
                                get: { models.activeModelID },
                                set: { models.activeModelID = $0 }
                            ), options: ModelStore.catalog.map { m in
                                .init(LocalizedStringKey(m.name), value: m.id)
                            }, width: 200)
                        }

                        ActiveModelStatusRow()
                            .padding(.vertical, 4)

                        Divider().background(Color.uiHairline)

                        HStack {
                            Text("Аппаратное ускорение")
                                .font(.ui(.body, weight: .medium))
                                .foregroundColor(.uiInk)
                            Spacer()
                            Text("Apple Metal")
                                .font(.ui(.footnote))
                                .foregroundColor(.uiMidGray)
                        }
                        
                        Divider().background(Color.uiHairline)

                        HStack {
                            Text("О программе Tranq")
                                .font(.ui(.body, weight: .medium))
                                .foregroundColor(.uiInk)
                            Spacer()
                            UIOutlineButton(title: "Открыть") {
                                showingAboutSheet = true
                            }
                        }
                        .sheet(isPresented: $showingAboutSheet) {
                            AboutView()
                        }

                        Divider().background(Color.uiHairline)

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
                }
                
                // РАЗДЕЛ 3.5: ГОЛОСОВОЙ ВВОД И СИНТЕЗ
                VoiceIntelligenceSection()

                // РАЗДЕЛ 3.55: ПРАВИЛА ПРИЛОЖЕНИЙ
                RulesSettingsSection()

                // РАЗДЕЛ 3.6: ИИ-ПРОВАЙДЕР
                AIProviderSection()

                // РАЗДЕЛ 4: ДАННЫЕ
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
            .padding(20)
        }
        .background(Color.uiCanvas)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refreshPermissions()
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
