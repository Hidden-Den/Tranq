import SwiftUI

// MARK: - Страница набора

/// Слова набора только для чтения, у каждого слова выключатель.
struct DictionaryPackDetailView: View {
    @ObservedObject private var store = DictionaryStore.shared

    let pack: DictionaryPack
    let uiLanguage: DictionaryLanguage
    let onBack: () -> Void

    private let language = DictionaryLanguage.current

    private var packEnabled: Bool { !store.disabledPacks.contains(pack.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pack.entries.enumerated()), id: \.offset) { offset, entry in
                        row(entry)
                        if offset < pack.entries.count - 1 {
                            Divider().background(Color.uiHairline)
                        }
                    }
                }
                .dictionarySectionBox()
                .opacity(packEnabled ? 1 : 0.5)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.uiCanvas)
        .onExitCommand(perform: onBack)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.ui(.body, weight: .semibold))
                    .foregroundColor(.uiInk)
                    .frame(width: 28, height: 28)
                    .background(Color.uiPaper)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.uiHairline, lineWidth: 1))
            }
            .buttonStyle(TactileButtonStyle())
            .accessibilityLabel(Text("Наборы"))

            Text(DictionaryScreenLogic.packTitle(pack, uiLanguage: uiLanguage))
                .font(.ui(.title, weight: .bold))
                .foregroundColor(.uiInk)
            Text("\(pack.entries.count) слов")
                .font(.ui(.footnote))
                .foregroundColor(.uiMidGray)
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .overlay(Divider().background(Color.uiHairline), alignment: .bottom)
    }

    private func row(_ entry: PackEntry) -> some View {
        let key = DictionaryScreenLogic.packWordKey(packId: pack.id, spelling: entry.spelling)
        let variants = DictionaryScreenLogic.packVariants(
            entry, packId: pack.id, language: language, disabled: store.disabledPackVariants
        )
        return HStack(spacing: 12) {
            Text(entry.spelling)
                .font(.ui(.body, weight: .medium))
                .foregroundColor(.uiInk)
            Text(variants.joined(separator: " · "))
                .font(.ui(.footnote))
                .foregroundColor(.uiMidGray)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Toggle(entry.spelling, isOn: Binding(
                get: { !store.disabledPackWords.contains(key) },
                set: { store.setPackWord(key, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
            .controlSize(.small)
            .disabled(!packEnabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
