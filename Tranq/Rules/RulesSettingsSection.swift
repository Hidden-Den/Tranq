import SwiftUI

// MARK: - Секция «Приложения»

/// Список правил: какой тон текста в каком приложении или на каком сайте.
struct RulesSettingsSection: View {
    @ObservedObject var store = DictationRuleStore.shared
    @State private var showingEditor = false

    var body: some View {
        UICard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Приложения")
                            .textCase(.uppercase)
                            .font(.ui(.caption, weight: .bold))
                            .tracking(1.0)
                            .foregroundColor(.uiMidGray)
                        Text("Тон текста по приложению или сайту")
                            .font(.ui(.caption))
                            .foregroundColor(.uiMidGray)
                    }
                    Spacer()
                    UIOutlineButton(title: "Добавить") { showingEditor = true }
                }

                if store.rules.isEmpty {
                    Text("Правил нет, везде чистый текст")
                        .font(.ui(.body))
                        .foregroundColor(.uiMidGray)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.rules.enumerated()), id: \.element.id) { index, rule in
                            if index > 0 { Divider().background(Color.uiHairline) }
                            RuleRow(rule: rule, store: store)
                                .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            RuleEditorSheet()
        }
    }
}

private struct RuleRow: View {
    let rule: DictationRule
    let store: DictationRuleStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.displayName)
                    .font(.ui(.body, weight: .medium))
                    .foregroundColor(.uiInk)
                    .lineLimit(1)
                toneText
                    .font(.ui(.caption))
                    .foregroundColor(.uiMidGray)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Toggle(rule.displayName, isOn: Binding(
                get: { rule.isEnabled },
                set: { newValue in
                    var changed = rule
                    changed.isEnabled = newValue
                    store.update(changed)
                }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
            Button {
                store.remove(id: rule.id)
            } label: {
                Image(systemName: "trash")
                    .font(.ui(.body))
                    .foregroundColor(.uiMidGray)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Удалить"))
        }
    }

    private var toneText: Text {
        switch rule.tone {
        case .business: return Text("Деловой")
        case .casual: return Text("Живой")
        case .custom(let text): return Text(text)
        }
    }
}
