import SwiftUI

// MARK: - Секция «Доступ для нейронок»

/// Три выключателя доступа и блок конфига для клиента нейронки.
/// Полный доступ и историю нельзя включить без подтверждения: флаг ставится только после согласия.
/// Эти два выключателя видны только при включённом доступе: пока дверь закрыта, они ничего не решают.
struct MCPSettingsSection: View {
    @ObservedObject var access = MCPAccess.shared

    /// Выключатель с предупреждением, который человек пытается включить, пока не подтвердит.
    @State private var confirming: RiskyAccess?

    private enum RiskyAccess {
        case fullAccess, history

        var title: LocalizedStringKey {
            switch self {
            case .fullAccess: return "Включить полный доступ?"
            case .history: return "Включить доступ к истории?"
            }
        }

        var message: LocalizedStringKey {
            switch self {
            case .fullAccess:
                return "Нейронка сможет удалить из словаря любое слово, даже добавленное вами вручную. Такие слова не вернуть."
            case .history:
                return "Диктовки уйдут в стороннюю модель вместе со всем, что в них есть, например письмами, заметками и рабочими записями."
            }
        }
    }

    var body: some View {
        UICard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ДОСТУП ДЛЯ НЕЙРОНОК")
                        .font(.ui(.caption, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(.uiMidGray)
                    Text("Нейронка поможет вести словарь")
                        .font(.ui(.caption))
                        .foregroundColor(.uiMidGray)
                }

                switchRow("Доступ", subtitle: "Читать словарь, добавлять слова", isOn: $access.enabled)

                if access.enabled {
                    Divider().background(Color.uiHairline)
                    switchRow("Полный доступ", subtitle: "Удалять слова и выключать наборы", isOn: fullAccessBinding)

                    Divider().background(Color.uiHairline)
                    switchRow("История", subtitle: "Читать ваши диктовки", isOn: historyBinding)

                    if let executable = Bundle.main.executableURL {
                        Divider().background(Color.uiHairline)
                        configBlock(MCPConfigSnippet.text(binaryURL: executable))
                    }
                }
            }
        }
        .alert(
            confirming?.title ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { risk in
            Button("Включить", role: .destructive) { grant(risk) }
            Button("Отмена", role: .cancel) {}
        } message: { risk in
            Text(risk.message)
        }
    }

    // MARK: Строки

    /// Включение только после подтверждения: выключатель сам остаётся выключенным, пока флаг не поставлен.
    /// Выключение подтверждения не просит.
    private var fullAccessBinding: Binding<Bool> {
        Binding(
            get: { access.fullAccess },
            set: { on in
                if on { confirming = .fullAccess } else { access.fullAccess = false }
            }
        )
    }

    private var historyBinding: Binding<Bool> {
        Binding(
            get: { access.historyAccess },
            set: { on in
                if on { confirming = .history } else { access.historyAccess = false }
            }
        )
    }

    private func grant(_ risk: RiskyAccess) {
        switch risk {
        case .fullAccess: access.fullAccess = true
        case .history: access.historyAccess = true
        }
    }

    private func switchRow(_ title: LocalizedStringKey, subtitle: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.ui(.body, weight: .medium))
                    .foregroundColor(.uiInk)
                Text(subtitle)
                    .font(.ui(.caption))
                    .foregroundColor(.uiMidGray)
            }
            Spacer()
            Toggle(isOn: isOn) { Text(title) }
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
        }
    }

    // MARK: Конфиг

    /// Текст конфига и одна кнопка копирования. Кнопка сама на пару секунд показывает, что скопировано.
    private func configBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Конфиг")
                        .font(.ui(.body, weight: .medium))
                        .foregroundColor(.uiInk)
                    Text("Вставьте в настройки клиента")
                        .font(.ui(.caption))
                        .foregroundColor(.uiMidGray)
                }
                Spacer()
                CopyFeedbackButton(textToCopy: text)
            }
            Text(verbatim: text)
                .font(.ui(.footnote, design: .monospaced))
                .foregroundColor(.uiInk)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.uiCanvas)
                .cornerRadius(UIRadius.sm)
                .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
        }
    }
}
