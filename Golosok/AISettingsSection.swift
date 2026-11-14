import SwiftUI
import AppKit

// MARK: - Секция «ИИ-провайдер»

struct AIProviderSection: View {
    @ObservedObject var store = AIProviderStore.shared

    var body: some View {
        UICard {
            VStack(alignment: .leading, spacing: 16) {
                Text("ИИ-ПРОВАЙДЕР")
                    .font(UIStyleFont.body(size: 11, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(.uiMidGray)

                Text(LocalizedStringKey("BYO-ключ. Транскрипция уходит напрямую в ваш OpenAI-совместимый сервис — Голосок не выступает оператором данных."))
                    .font(UIStyleFont.body(size: 11, weight: .regular))
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

                AIInputField(title: "Base URL", text: $store.baseURL, placeholder: "https://api.openai.com/v1")
                AIInputField(title: "API-ключ", text: $store.apiKey, placeholder: "sk-…", isSecure: true)

                if store.providerID == "ollama" {
                    ollamaModelField
                } else {
                    AIInputField(title: "Модель", text: $store.model, placeholder: "gpt-4o-mini")
                }

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
                            .font(UIStyleFont.body(size: 12, weight: .medium))
                            .foregroundColor(store.testOK ? Color(hex: "#10B981") : .uiEmber)
                            .lineLimit(2)
                    }
                    Spacer()
                }
            }
        }
    }

    private var ollamaModelField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Модель")
                .font(UIStyleFont.body(size: 11, weight: .medium))
                .foregroundColor(.uiMidGray)
            HStack(spacing: 8) {
                UIDropdownPicker(selection: $store.model, options: {
                    var arr: [UIDropdownOption<String>] = []
                    if !store.model.isEmpty && !store.installedModels.contains(store.model) {
                        arr.append(.init(store.model, value: store.model))
                    }
                    arr.append(contentsOf: store.installedModels.map { .init($0, value: $0) })
                    return arr
                }(), fullWidth: true)

                Button(action: { store.refreshModels() }) {
                    if store.isLoadingModels {
                        ProgressView().controlSize(.small)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.uiInk)
                            .frame(width: 28, height: 28)
                    }
                }
                .buttonStyle(TactileButtonStyle())
                .background(Color.uiPaper)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.uiHairline, lineWidth: 1))
                .help(String(localized: "Обновить список моделей"))
            }
            if store.installedModels.isEmpty && !store.isLoadingModels {
                Text("Нет скачанных моделей — запустите Ollama и нажмите ↻")
                    .font(UIStyleFont.body(size: 11, weight: .regular))
                    .foregroundColor(.uiMidGray)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if store.installedModels.isEmpty && !store.isLoadingModels {
                store.refreshModels()
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
                    .font(UIStyleFont.body(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? .uiPaper : .uiInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? Color.uiInk : Color.uiPaper)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.uiInk : Color.uiHairline, lineWidth: 1))
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
                .font(UIStyleFont.body(size: 11, weight: .medium))
                .foregroundColor(.uiMidGray)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(PlainTextFieldStyle())
            .font(UIStyleFont.body(size: 13, weight: .regular))
            .foregroundColor(.uiInk)
            .padding(8)
            .background(Color.uiCanvas)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
        }
    }
}

// MARK: - Секция «Голосовой ввод и синтез»

struct VoiceIntelligenceSection: View {
    @ObservedObject var settings = VoiceIntelligenceSettings.shared

    var body: some View {
        UICard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("ГОЛОСОВОЙ ВВОД И СИНТЕЗ")
                        .font(UIStyleFont.body(size: 11, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(.uiMidGray)
                    Spacer()
                    UIBadge(text: settings.mode == .smart ? "Умная речь" : "Прямой")
                }

                // Переключатель режима
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Умная речь")
                            .font(UIStyleFont.body(size: 13, weight: .medium))
                            .foregroundColor(.uiInk)
                        Text(settings.mode == .smart ? "Очистка от паразитов и синтез мысли" : "Дословная расшифровка без изменений")
                            .font(UIStyleFont.body(size: 11, weight: .regular))
                            .foregroundColor(.uiMidGray)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { settings.mode == .smart },
                        set: { settings.mode = $0 ? .smart : .direct }
                    ))
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#10B981")))
                }

                if settings.mode == .smart {
                    Divider().background(Color.uiHairline)

                    // Стиль мысли
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Стиль текста")
                                .font(UIStyleFont.body(size: 13, weight: .medium))
                                .foregroundColor(.uiInk)
                            Text("Формат оформления очищенной мысли")
                                .font(UIStyleFont.body(size: 11, weight: .regular))
                                .foregroundColor(.uiMidGray)
                        }
                        Spacer()
                        UIDropdownPicker(selection: $settings.style, options: VoiceStyle.allCases.map { s in
                            .init(LocalizedStringKey(s.title), value: s)
                        }, width: 160)
                    }

                    Divider().background(Color.uiHairline)

                    // Движок обработки
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Движок синтеза")
                                .font(UIStyleFont.body(size: 13, weight: .medium))
                                .foregroundColor(.uiInk)
                            Text(LocalizedStringKey(settings.engine.subtitle))
                                .font(UIStyleFont.body(size: 11, weight: .regular))
                                .foregroundColor(.uiMidGray)
                        }
                        Spacer()
                        UIDropdownPicker(selection: $settings.engine, options: VoiceEngine.allCases.map { e in
                            .init(LocalizedStringKey(e.title), value: e)
                        }, width: 210)
                    }
                }
            }
        }
    }
}
