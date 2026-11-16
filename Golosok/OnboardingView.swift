import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions = PermissionManager.shared
    @ObservedObject var hotKey = HotKeySettings.shared
    @Binding var isPresented: Bool
    
    var canContinue: Bool {
        return permissions.isMicGranted
    }
    
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            Color.uiCanvas.ignoresSafeArea()
            
            VStack(spacing: 24) {
                // ШАПКА
                VStack(spacing: 8) {
                    Text("Давайте начнём")
                        .font(.ui(.title, weight: .semibold))
                        .foregroundColor(.uiInk)
                    
                    Text("Разрешите доступ к микрофону для записи речи.\nОстальные опции можно настроить позже.")
                        .font(.ui(.body))
                        .foregroundColor(.uiMidGray)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 420)
                
                // КАРТОЧКА НАСТРОЕК
                UICard {
                    VStack(spacing: 18) {
                        // ШАГ 1: Микрофон (Обязательно)
                        HStack(spacing: 16) {
                            Circle()
                                .fill(permissions.isMicGranted ? Color.uiSuccess : Color.uiWarn)
                                .frame(width: 10, height: 10)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Доступ к микрофону")
                                        .font(.ui(.callout, weight: .medium))
                                        .foregroundColor(.uiInk)
                                    Text("Требуется")
                                        .font(.ui(.micro, weight: .bold))
                                        .foregroundColor(.uiWarn)
                                }
                                Text("Запись голоса для распознавания моделью")
                                    .font(.ui(.footnote))
                                    .foregroundColor(.uiMidGray)
                            }
                            
                            Spacer()
                            
                            if permissions.isMicGranted {
                                UIBadge(text: String(localized: "Готово"))
                            } else {
                                UIPrimaryButton(title: "Разрешить") {
                                    permissions.requestMicPermission()
                                }
                            }
                        }
                        
                        Divider().background(Color.uiHairline)
                        
                        // ШАГ 2: Авто-вставка (По желанию)
                        HStack(spacing: 16) {
                            Circle()
                                .fill(permissions.isAccessibilityGranted ? Color.uiSuccess : Color.uiMidGray.opacity(0.4))
                                .frame(width: 10, height: 10)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Вставка под курсор")
                                        .font(.ui(.callout, weight: .medium))
                                        .foregroundColor(.uiInk)
                                    Text("Опционально")
                                        .font(.ui(.micro))
                                        .foregroundColor(.uiMidGray)
                                }
                                Text("Мгновенная вставка распознанного текста в активное окно")
                                    .font(.ui(.footnote))
                                    .foregroundColor(.uiMidGray)
                            }
                            
                            Spacer()
                            
                            if permissions.isAccessibilityGranted {
                                UIBadge(text: String(localized: "Готово"))
                            } else {
                                UIOutlineButton(title: "Включить") {
                                    permissions.requestAccessibilityPermission()
                                }
                            }
                        }

                        Divider().background(Color.uiHairline)

                        // ШАГ 3: Горячая клавиша (По выбору)
                        HStack(spacing: 16) {
                            Circle()
                                .fill(hotKey.isConfigured ? Color.uiSuccess : Color.uiMidGray.opacity(0.4))
                                .frame(width: 10, height: 10)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Горячая клавиша")
                                        .font(.ui(.callout, weight: .medium))
                                        .foregroundColor(.uiInk)
                                    Text("По выбору")
                                        .font(.ui(.micro))
                                        .foregroundColor(.uiMidGray)
                                }
                                Text(hotKey.isConfigured ? "Назначена: \(hotKey.hotKeyName)" : "Выберите клавишу для старта диктовки")
                                    .font(.ui(.footnote))
                                    .foregroundColor(.uiMidGray)
                            }

                            Spacer()

                            HStack(spacing: 6) {
                                if hotKey.isConfigured {
                                    UIBadge(text: hotKey.hotKeyName)
                                    UIOutlineButton(title: "Сбросить") {
                                        hotKey.clear()
                                    }
                                } else {
                                    UIOutlineButton(title: "Fn") {
                                        hotKey.setPreset(.fnKey)
                                    }
                                    UIOutlineButton(title: "⌥ Пробел") {
                                        hotKey.setPreset(.optionSpace)
                                    }
                                    UIOutlineButton(title: "Правый ⌥") {
                                        hotKey.setPreset(.rightOptionKey)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 520)
                
                UIPrimaryButton(title: canContinue ? LocalizedStringKey("Начать использование") : LocalizedStringKey("Требуется доступ к микрофону")) {
                    if canContinue {
                        permissions.completeOnboarding()
                        isPresented = false
                    }
                }
                .disabled(!canContinue)
                .opacity(canContinue ? 1.0 : 0.4)
            }
            .padding(40)
        }
        .onReceive(timer) { _ in
            permissions.refreshPermissions()
        }
    }
}
