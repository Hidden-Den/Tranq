import SwiftUI

// MARK: - Окно добавления правила

/// Правило для приложения или сайта: куда относится и каким тоном писать.
struct RuleEditorSheet: View {
    @ObservedObject private var store = DictationRuleStore.shared
    @Environment(\.dismiss) private var dismiss

    private enum ToneChoice: Hashable { case business, casual, custom }

    private let apps = RuleEditorLogic.runningApps()
    @State private var kind: RuleDraft.Kind = .app
    @State private var bundleId = ""
    @State private var domain = ""
    @State private var toneChoice: ToneChoice = .business
    @State private var customText = ""
    @State private var error: RuleEditorError?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            UISegmented(selection: clearing($kind), segments: [
                UISegment(text: Text("Приложение"), value: RuleDraft.Kind.app),
                UISegment(text: Text("Сайт"), value: RuleDraft.Kind.site),
            ])

            if kind == .app {
                UIDropdownPicker(selection: clearing($bundleId), options: apps.map { app in
                    .init(app.name, value: app.bundleId)
                }, fullWidth: true)
            } else {
                TextField("mail.company.ru", text: clearing($domain))
                    .textFieldStyle(.plain)
                    .font(.ui(.body))
                    .foregroundColor(.uiInk)
                    .onSubmit(save)
                    .padding(8)
                    .background(Color.uiCanvas)
                    .cornerRadius(UIRadius.sm)
                    .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
            }

            UISegmented(selection: clearing($toneChoice), segments: [
                UISegment(text: Text("Деловой"), value: ToneChoice.business),
                UISegment(text: Text("Живой"), value: ToneChoice.casual),
                UISegment(text: Text("Свой"), value: ToneChoice.custom),
            ])

            if toneChoice == .custom {
                TextField("Как писать текст", text: clearing($customText))
                    .textFieldStyle(.plain)
                    .font(.ui(.body))
                    .foregroundColor(.uiInk)
                    .onSubmit(save)
                    .padding(8)
                    .background(Color.uiCanvas)
                    .cornerRadius(UIRadius.sm)
                    .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
            }

            HStack(spacing: 10) {
                if let error {
                    Text(Self.message(for: error))
                        .font(.ui(.footnote, weight: .medium))
                        .foregroundColor(.uiEmber)
                }
                Spacer()
                UIOutlineButton(title: "Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                UIPrimaryButton(title: "Добавить", action: save)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Color.uiPaper)
        .onAppear { bundleId = apps.first?.bundleId ?? "" }
    }

    /// Любая правка убирает показанную ошибку.
    private func clearing<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; error = nil })
    }

    private func save() {
        let tone: RuleTone
        switch toneChoice {
        case .business: tone = .business
        case .casual: tone = .casual
        case .custom: tone = .custom("")
        }
        let draft = RuleDraft(
            kind: kind,
            bundleId: bundleId.isEmpty ? nil : bundleId,
            appName: apps.first { $0.bundleId == bundleId }?.name,
            domainInput: domain,
            tone: tone,
            customText: customText
        )
        switch RuleEditorLogic.makeRule(from: draft, existing: store.rules) {
        case .success(let rule):
            store.add(rule)
            dismiss()
        case .failure(let failure):
            error = failure
        }
    }

    private static func message(for error: RuleEditorError) -> LocalizedStringKey {
        switch error {
        case .emptyTarget: return "Укажите приложение"
        case .invalidDomain: return "Неверный адрес"
        case .emptyCustomTone: return "Опишите тон"
        case .duplicate: return "Правило уже есть"
        }
    }
}
