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
                    Text("Tranq")
                        .font(.brand(34))
                        .foregroundColor(.uiInk)

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
                                    permissions.resolveMicPermission()
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
                                hotKeyHint
                            }

                            Spacer(minLength: 8)

                            // Тот же захват клавиши, что и в настройках: готовых наборов нет
                            HStack(spacing: 6) {
                                if hotKey.isCapturing {
                                    UIBadge(text: "…")
                                    UIOutlineButton(title: "Отмена") { hotKey.endCapture() }
                                } else if hotKey.isConfigured {
                                    UIBadge(text: hotKey.hotKeyName)
                                    UIOutlineButton(title: "Изменить") { hotKey.beginCapture() }
                                } else {
                                    UIOutlineButton(title: "Назначить") { hotKey.beginCapture() }
                                }
                            }
                            .fixedSize()
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
        // Захват держит локальный монитор клавиш: без этого он остался бы после закрытия экрана
        .onDisappear { hotKey.endCapture() }
    }

    /// Подсказка под названием: что делать сейчас или почему не вышло. У назначенной клавиши подсказки нет.
    @ViewBuilder private var hotKeyHint: some View {
        if let warning = hotKey.warningMessage {
            Text(warning).font(.ui(.footnote)).foregroundColor(.uiWarn)
        } else if hotKey.isCapturing {
            Text(LocalizedStringKey("HotKey.Capture")).font(.ui(.footnote)).foregroundColor(.uiMidGray)
        } else if hotKey.isTaken {
            Text(LocalizedStringKey("HotKey.Taken")).font(.ui(.footnote)).foregroundColor(.uiWarn)
        } else if !hotKey.isConfigured {
            Text("Нажмите кнопку и затем нужную клавишу").font(.ui(.footnote)).foregroundColor(.uiMidGray)
        }
    }
}
