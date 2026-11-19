import SwiftUI
import AppKit

/// Раздел «Диктовка»: клавиша, режим, отмена, авто-вставка и звуки.
struct DictationSettingsSection: View {
    @ObservedObject var preferences = AppPreferences.shared
    @ObservedObject var permissions = PermissionManager.shared
    @ObservedObject var hotKey = HotKeySettings.shared

    var body: some View {
        SettingsPage {
            UICard {
                VStack(alignment: .leading, spacing: 14) {
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

                    Divider().background(Color.uiHairline)

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
                            Text("Звуки")
                                .font(.ui(.body, weight: .medium))
                                .foregroundColor(.uiInk)
                            Text("Начало и конец записи, копирование, ошибки")
                                .font(.ui(.caption))
                                .foregroundColor(.uiMidGray)
                        }
                        Spacer()
                        Toggle("", isOn: $preferences.soundEnabled)
                            .labelsHidden()
                            .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
                    }

                    Divider().background(Color.uiHairline)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Подсветка окна")
                                .font(.ui(.body, weight: .medium))
                                .foregroundColor(.uiInk)
                            Text("Рамка вокруг окна диктовки")
                                .font(.ui(.caption))
                                .foregroundColor(.uiMidGray)
                        }
                        Spacer()
                        Toggle("", isOn: $preferences.windowHighlightEnabled)
                            .labelsHidden()
                            .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
                    }
                }
            }
        }
        // Права могли выдать в системных настройках: состояние доступа обновляется при возврате в приложение
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refreshPermissions()
        }
    }
}
