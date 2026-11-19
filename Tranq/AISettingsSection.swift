import SwiftUI
import AppKit

// MARK: - Секция «ИИ-провайдер»

struct AIProviderSection: View {
    @ObservedObject var store = AIProviderStore.shared

    var body: some View {
        UICard {
            VStack(alignment: .leading, spacing: 16) {
                Text("ИИ-ПРОВАЙДЕР")
                    .font(.ui(.caption, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(.uiMidGray)

                Text(LocalizedStringKey("BYO-ключ. Транскрипция уходит напрямую в выбранный вами сервис — Tranq не выступает оператором данных"))
                    .font(.ui(.caption))
                    .foregroundColor(.uiMidGray)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(AIProviderPresets.all) { preset in
                        PresetChip(preset: preset, isSelected: store.providerID == preset.id) {
                            store.apply(preset)
                        }
                    }
                }

                AIInputField(title: "Base URL", text: $store.baseURL, placeholder: store.providerID == "corporate" ? "https://gateway.company.ru/v1" : (store.currentPreset?.baseURL ?? "https://api.openai.com/v1"))
                AIInputField(title: "API-ключ", text: $store.apiKey, placeholder: "sk-…", isSecure: true)
                AIInputField(title: "Модель", text: $store.model, placeholder: store.currentPreset?.defaultModel ?? "gpt-6-luna")

                HStack(spacing: 10) {
                    UIOutlineButton(title: "Проверить") {
                        store.testConnection()
                    }
                    .disabled(store.isTesting)

                    if store.isTesting {
                        ProgressView().controlSize(.small)
                    }

                    if let result = store.testResult {
                        Text(result)
                            .font(.ui(.footnote, weight: .medium))
                            .foregroundColor(store.testOK ? Color.uiSuccess : .uiEmber)
                            .lineLimit(2)
                    }
                    Spacer()
                }

                TelemetryDisclosure()
            }
        }
    }
}

struct PresetChip: View {
    let preset: AIProviderPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isSelected ? Color.uiPaper : Color.uiMidGray)
                    .frame(width: 6, height: 6)
                Text(LocalizedStringKey(preset.name))
                    .font(.ui(.footnote, weight: .medium))
                    .foregroundColor(isSelected ? .uiPaper : .uiInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? Color.uiInk : Color.uiPaper)
            .cornerRadius(UIRadius.md)
            .overlay(RoundedRectangle(cornerRadius: UIRadius.md).stroke(isSelected ? Color.uiInk : Color.uiHairline, lineWidth: 1))
        }
        .buttonStyle(TactileButtonStyle())
    }
}

struct AIInputField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var placeholder: String = ""
    var isSecure: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.ui(.caption, weight: .medium))
                .foregroundColor(.uiMidGray)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(PlainTextFieldStyle())
            .font(.ui(.body))
            .foregroundColor(.uiInk)
            .padding(8)
            .background(Color.uiCanvas)
            .cornerRadius(UIRadius.sm)
            .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
        }
    }
}

// MARK: - Секция «Голосовой ввод и синтез»

struct VoiceIntelligenceSection: View {
    @ObservedObject var settings = VoiceIntelligenceSettings.shared
    @ObservedObject var hotKey = HotKeySettings.shared

    var body: some View {
        UICard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("ГОЛОСОВОЙ ВВОД И СИНТЕЗ")
                        .font(.ui(.caption, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(.uiMidGray)
                    Spacer()
                    UIBadge(text: settings.mode == .smart ? "Умная речь" : "Прямой")
                }

                // Переключатель режима
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Умная речь")
                            .font(.ui(.body, weight: .medium))
                            .foregroundColor(.uiInk)
                        Text(settings.mode == .smart ? "Очистка от паразитов и синтез мысли" : "Только звуки и заикания, без ИИ")
                            .font(.ui(.caption))
                            .foregroundColor(.uiMidGray)
                    }
                    Spacer()
                    Toggle(String(localized: "Умная речь"), isOn: Binding(
                        get: { settings.mode == .smart },
                        set: { settings.mode = $0 ? .smart : .direct }
                    ))
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
                }

                if settings.mode == .smart {
                    Divider().background(Color.uiHairline)

                    // Движок обработки
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Движок синтеза")
                                .font(.ui(.body, weight: .medium))
                                .foregroundColor(.uiInk)
                            Text(LocalizedStringKey(settings.engine.subtitle))
                                .font(.ui(.caption))
                                .foregroundColor(.uiMidGray)
                        }
                        Spacer()
                        UIDropdownPicker(selection: $settings.engine, options: VoiceEngine.allCases.map { e in
                            .init(LocalizedStringKey(e.title), value: e)
                        }, width: 210)
                    }

                    if settings.engine == .airGapped {
                        Divider().background(Color.uiHairline)

                        // Языковая модель SLM на устройстве
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Модель обработки")
                                    .font(.ui(.body, weight: .medium))
                                    .foregroundColor(.uiInk)
                                Text("Оффлайн SLM для Apple Silicon")
                                    .font(.ui(.caption))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()
                            UIDropdownPicker(selection: $settings.localModel, options: SLMModelStore.catalog.map { m in
                                .init(LocalizedStringKey(SLMRecommendation.pickerLabel(for: m)), value: m.id)
                            }, width: 240)
                        }

                        ActiveSLMModelStatusRow(modelID: settings.localModel)
                            .padding(.vertical, 4)
                    }

                    Divider().background(Color.uiHairline)

                    // Словарь
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Словарь")
                                .font(.ui(.body, weight: .medium))
                                .foregroundColor(.uiInk)
                            Text("Свои слова и наборы терминов")
                                .font(.ui(.caption))
                                .foregroundColor(.uiMidGray)
                        }
                        Spacer()
                        UIOutlineButton(title: "Открыть") {
                            NotificationCenter.default.post(name: NSNotification.Name("OpenVocabularyTab"), object: nil)
                        }
                    }

                    Divider().background(Color.uiHairline)

                    // Правила
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Правила")
                                .font(.ui(.body, weight: .medium))
                                .foregroundColor(.uiInk)
                            Text("Тон и режим для каждого приложения")
                                .font(.ui(.caption))
                                .foregroundColor(.uiMidGray)
                        }
                        Spacer()
                        UIOutlineButton(title: "Открыть") {
                            NotificationCenter.default.post(name: NSNotification.Name("OpenRulesTab"), object: nil)
                        }
                    }

                    Divider().background(Color.uiHairline)

                    // Инструкция модели
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center) {
                            Text("Инструкция модели")
                                .font(.ui(.body, weight: .medium))
                                .foregroundColor(.uiInk)
                            Spacer()
                            UIOutlineButton(title: "По умолчанию") {
                                settings.customSystemPrompt = VoiceIntelligenceSettings.defaultCustomPrompt
                            }
                            .disabled(settings.customSystemPrompt == VoiceIntelligenceSettings.defaultCustomPrompt)
                        }
                        TextEditor(text: $settings.customSystemPrompt)
                            .font(.ui(.footnote, design: .monospaced))
                            .foregroundColor(.uiInk)
                            .lineSpacing(3)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(height: 160)
                            .background(Color.uiCanvas)
                            .cornerRadius(UIRadius.sm)
                            .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
                            .accessibilityLabel(Text("Инструкция модели"))
                    }
                }

                Divider().background(Color.uiHairline)

                promptModeRow
            }
        }
    }

    /// Режим промпта: основная клавиша с Shift запускает одну диктовку как запрос к нейросети.
    private var promptModeRow: some View {
        let hint = PromptModeHint.make(for: hotKey.trigger)
        let isAvailable: Bool = { if case .available = hint { return true } else { return false } }()
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Режим промпта")
                    .font(.ui(.body, weight: .medium))
                    .foregroundColor(.uiInk)
                Group {
                    switch hint {
                    case .available(let combo): Text("\(combo) на одну диктовку")
                    case .unavailableShift: Text("Недоступно с клавишей Shift")
                    case .noHotKey: Text("Нет горячей клавиши")
                    }
                }
                .font(.ui(.caption))
                .foregroundColor(.uiMidGray)
            }
            Spacer()
            Toggle(String(localized: "Режим промпта"), isOn: Binding(
                get: { settings.promptModeEnabled },
                set: { newValue in
                    settings.promptModeEnabled = newValue
                    NativeHotKeyManager.shared.refreshPromptRegistration()
                }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
            .disabled(!isAvailable && !settings.promptModeEnabled)
        }
    }
}

struct ActiveSLMModelStatusRow: View {
    let modelID: String
    @ObservedObject var slmStore = SLMModelStore.shared

    var body: some View {
        if let model = slmStore.model(named: modelID) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(LocalizedStringKey(model.name))
                            .font(.ui(.body, weight: .medium))
                            .foregroundColor(.uiInk)
                            .lineLimit(1)
                        if SLMRecommendation.isRecommended(model) {
                            Text("Рекомендуем")
                                .font(.ui(.micro))
                                .foregroundColor(.uiSuccess)
                        }
                    }
                    Text("\(model.sizeMB) МБ — Apple Metal")
                        .font(.ui(.caption))
                        .foregroundColor(.uiMidGray)
                        .lineLimit(1)
                    Text(LocalizedStringKey(model.description))
                        .font(.ui(.caption))
                        .foregroundColor(.uiMidGray)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                if slmStore.downloadingID == model.id {
                    HStack(spacing: 8) {
                        VStack(alignment: .trailing, spacing: 4) {
                            ProgressView(value: slmStore.downloadProgress)
                                .frame(width: 170)
                            Text(LocalizedStringKey(slmStore.downloadStatus))
                                .font(.ui(.micro))
                                .foregroundColor(.uiMidGray)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .frame(width: 170, alignment: .trailing)

                        UIOutlineButton(title: "Отмена") {
                            slmStore.cancelDownload()
                        }
                    }
                } else if slmStore.isModelDownloaded(model) {
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.uiSuccess)
                                .frame(width: 6, height: 6)
                            Text("Скачана на Mac")
                                .font(.ui(.caption, weight: .medium))
                                .foregroundColor(Color.uiSuccess)
                                .lineLimit(1)
                        }
                        UIOutlineButton(title: "Удалить") {
                            slmStore.delete(model: model)
                        }
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
                        UIOutlineButton(title: "Скачать") {
                            slmStore.startDownload(model: model)
                        }
                    }
                }
            }
            .frame(minHeight: 52)
        }
    }
}


