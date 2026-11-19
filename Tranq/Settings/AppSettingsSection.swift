import SwiftUI

/// Раздел «Приложение»: язык, цвет, запуск, Dock, история и «О программе».
struct AppSettingsSection: View {
    @ObservedObject var preferences = AppPreferences.shared
    @ObservedObject var language = LanguageSettings.shared
    @ObservedObject var theme = ThemeSettings.shared
    @State private var showingAboutSheet = false

    var body: some View {
        SettingsPage {
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

            UICard {
                VStack(alignment: .leading, spacing: 16) {
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
                }
            }
        }
    }
}
