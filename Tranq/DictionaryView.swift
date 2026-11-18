import SwiftUI

// MARK: - Экран словаря

/// «Мои слова», наборы и обучение, поиск по всем словам и окно добавления.
struct DictionaryView: View {
    @ObservedObject private var store = DictionaryStore.shared

    @State private var query = ""
    @State private var expandedID: UUID?
    @State private var addingWord = false
    @State private var confirmingReset = false
    @State private var confirmingAgentRevert = false
    @State private var openPackID: String?

    private let language = DictionaryLanguage.current
    private let uiLanguage = DictionaryScreenLogic.currentUILanguage

    var body: some View {
        Group {
            if let id = openPackID, let pack = store.packs.first(where: { $0.id == id }) {
                DictionaryPackDetailView(pack: pack, uiLanguage: uiLanguage) { openPackID = nil }
            } else {
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                myWordsSection
                                packsSection
                                learningSection
                            } else {
                                searchResults
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.uiCanvas)
        .sheet(isPresented: $addingWord) { DictionaryAddWordSheet() }
        // Второе окно подтверждения висит на разделе «Мои слова»: два `.alert` на одном виде
        // SwiftUI не показывает оба.
        .alert("Сбросить выученное", isPresented: $confirmingReset) {
            Button("Сбросить", role: .destructive) { store.resetLearned() }
            Button("Отмена", role: .cancel) {}
        }
    }

    // MARK: Заголовок

    private var header: some View {
        HStack(spacing: 12) {
            Text("Словарь")
                .font(.ui(.title, weight: .bold))
                .foregroundColor(.uiInk)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.ui(.caption))
                    .foregroundColor(.uiMidGray)
                TextField("Поиск", text: $query)
                    .textFieldStyle(.plain)
                    .font(.ui(.footnote))
                    .foregroundColor(.uiInk)
                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.ui(.caption))
                            .foregroundColor(.uiMidGray)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 220)
            .background(Color.uiPaper)
            .cornerRadius(UIRadius.sm)
            .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))

            Button(action: { addingWord = true }) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.ui(.caption, weight: .bold))
                    Text("Слово")
                        .font(.ui(.body, weight: .medium))
                }
                .foregroundColor(Color.dynamic(light: "#ffffff", dark: "#000000"))
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .background(Color.uiInk)
                .cornerRadius(UIRadius.lg)
            }
            .buttonStyle(TactileButtonStyle())
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .overlay(Divider().background(Color.uiHairline), alignment: .bottom)
    }

    // MARK: Мои слова

    private var myWordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionTitle("Мои слова")
                Spacer()
                Text(store.userEntries.count, format: .number)
                    .font(.ui(.footnote, weight: .medium))
                    .foregroundColor(.uiMidGray)
                    .monospacedDigit()
                UIDropdownMenu(items: menuItems, minWidth: 200) {
                    Image(systemName: "ellipsis")
                        .font(.ui(.body, weight: .semibold))
                        .foregroundColor(.uiMidGray)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
            }

            if store.userEntries.isEmpty {
                Text("Пока пусто")
                    .font(.ui(.body))
                    .foregroundColor(.uiMidGray)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.userEntries) { entry in
                        DictionaryWordRow(
                            entry: entry,
                            language: language,
                            isExpanded: expandedID == entry.id,
                            onToggle: { toggle(entry.id) }
                        )
                        if entry.id != store.userEntries.last?.id {
                            Divider().background(Color.uiHairline)
                        }
                    }
                }
                .dictionarySectionBox()
            }
        }
        .alert("Снять слова агента", isPresented: $confirmingAgentRevert) {
            Button("Снять", role: .destructive) { store.revertAgentChanges() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Удалятся слова, варианты и наборы агента. Ваши останутся.")
        }
    }

    /// «Снять слова агента» появляется, только пока в словаре есть что снимать.
    private var menuItems: [UIDropdownItem] {
        var items: [UIDropdownItem] = [
            .action("Сбросить выученное", icon: "arrow.counterclockwise") { confirmingReset = true },
        ]
        if store.agentWordCount > 0 || !store.agentPacks.isEmpty {
            items.append(.action("Снять слова агента", icon: "arrow.uturn.backward") { confirmingAgentRevert = true })
        }
        return items
    }

    private func toggle(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.15)) {
            expandedID = expandedID == id ? nil : id
        }
    }

    // MARK: Наборы

    private var packsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Наборы")
            VStack(spacing: 0) {
                ForEach(store.packs) { pack in
                    packRow(pack)
                    if pack.id != store.packs.last?.id {
                        Divider().background(Color.uiHairline)
                    }
                }
            }
            .dictionarySectionBox()
        }
    }

    private func packRow(_ pack: DictionaryPack) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(DictionaryScreenLogic.packTitle(pack, uiLanguage: uiLanguage))
                    .font(.ui(.body, weight: .medium))
                    .foregroundColor(.uiInk)
                Text("\(pack.entries.count) слов")
                    .font(.ui(.footnote))
                    .foregroundColor(.uiMidGray)
                if store.agentPacks.contains(where: { $0.id == pack.id }) {
                    Text("от агента")
                        .font(.ui(.caption))
                        .foregroundColor(.uiMidGray)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.ui(.caption, weight: .semibold))
                    .foregroundColor(.uiMidGray)
            }
            .contentShape(Rectangle())
            .onTapGesture { openPackID = pack.id }

            Toggle(DictionaryScreenLogic.packTitle(pack, uiLanguage: uiLanguage), isOn: Binding(
                get: { !store.disabledPacks.contains(pack.id) },
                set: { store.setPack(pack.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Обучение

    private var learningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Обучение")
            HStack {
                Text("Учиться на правках")
                    .font(.ui(.body, weight: .medium))
                    .foregroundColor(.uiInk)
                Spacer()
                Toggle(String(localized: "Учиться на правках"), isOn: $store.learningEnabled)
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .dictionarySectionBox()
        }
    }

    // MARK: Поиск

    private var searchResults: some View {
        let results = DictionaryScreenLogic.search(query, userEntries: store.userEntries, packs: store.packs)
        return Group {
            if results.isEmpty {
                Text("Не найдено")
                    .font(.ui(.body))
                    .foregroundColor(.uiMidGray)
            } else {
                VStack(spacing: 0) {
                    ForEach(results) { result in
                        searchRow(result)
                        if result.id != results.last?.id {
                            Divider().background(Color.uiHairline)
                        }
                    }
                }
                .dictionarySectionBox()
            }
        }
    }

    @ViewBuilder
    private func searchRow(_ result: DictionaryScreenLogic.SearchResult) -> some View {
        switch result.source {
        case .user(let id):
            if let entry = store.userEntries.first(where: { $0.id == id }) {
                DictionaryWordRow(entry: entry, language: language, isExpanded: expandedID == id, onToggle: { toggle(id) })
            }
        case .pack(let packID):
            let pack = store.packs.first { $0.id == packID }
            HStack(spacing: 12) {
                Text(result.spelling)
                    .font(.ui(.body, weight: .medium))
                    .foregroundColor(.uiInk)
                Text(DictionaryScreenLogic.variantLine(result.variants, language: language))
                    .font(.ui(.footnote))
                    .foregroundColor(.uiMidGray)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if let pack {
                    Text(DictionaryScreenLogic.packTitle(pack, uiLanguage: uiLanguage))
                        .font(.ui(.caption))
                        .foregroundColor(.uiMidGray)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { openPackID = packID }
        }
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.ui(.callout, weight: .semibold))
            .foregroundColor(.uiInk)
    }
}

// MARK: - Строка слова

/// Свёрнутая: написание, варианты языка диктовки, метка «выучено».
/// Раскрытая: варианты RU и EN с крестиками, «+ вариант», 🎙 и удаление.
struct DictionaryWordRow: View {
    @ObservedObject private var store = DictionaryStore.shared

    let entry: DictionaryEntry
    let language: DictionaryLanguage
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var addingLanguage: DictionaryLanguage?
    @State private var newVariant = ""
    @State private var rejected = false
    @State private var pendingRemoval: (variant: String, language: DictionaryLanguage)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(entry.spelling)
                    .font(.ui(.body, weight: .medium))
                    .foregroundColor(.uiInk)
                Text(DictionaryScreenLogic.variantLine(entry.variants, language: language))
                    .font(.ui(.footnote))
                    .foregroundColor(.uiMidGray)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if entry.source == .learned {
                    Text("выучено")
                        .font(.ui(.caption))
                        .foregroundColor(.uiMidGray)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(DictionaryLanguage.allCases, id: \.self) { lang in
                        languageLine(lang)
                    }
                    HStack(spacing: 10) {
                        WordProbeControl(spelling: entry.spelling) { variant in
                            addVariant(variant, language: DictionaryLanguage.current)
                        }
                        Button(action: { store.removeEntry(id: entry.id) }) {
                            Image(systemName: "trash")
                                .font(.ui(.caption, weight: .medium))
                                .foregroundColor(.uiMidGray)
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(TactileButtonStyle())
                        .help(Text("Удалить"))
                        .accessibilityLabel(Text("Удалить"))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .alert("Удалить слово", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let pending = pendingRemoval { removeVariant(pending.variant, language: pending.language) }
                pendingRemoval = nil
            }
            Button("Отмена", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Это последний вариант")
        }
    }

    /// Последний вариант выученного слова удаляет слово целиком, поэтому сначала спрашиваем.
    private func requestRemoval(_ variant: String, language lang: DictionaryLanguage) {
        if DictionaryScreenLogic.removalDeletesEntry(entry, variant: variant, language: lang) {
            pendingRemoval = (variant, lang)
        } else {
            removeVariant(variant, language: lang)
        }
    }

    private func removeVariant(_ variant: String, language lang: DictionaryLanguage) {
        store.removeVariant(variant, language: lang, fromEntryKey: "user/\(entry.id.uuidString)")
    }

    private func languageLine(_ lang: DictionaryLanguage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: lang.rawValue.uppercased())
                .font(.ui(.micro, weight: .semibold))
                .foregroundColor(.uiMidGray)
                .frame(width: 22, alignment: .leading)
            FlowLayout(spacing: 6) {
                ForEach(entry.variants[lang] ?? [], id: \.self) { variant in
                    VariantChip(text: variant) { requestRemoval(variant, language: lang) }
                }
                if addingLanguage == lang {
                    TextField("", text: $newVariant)
                        .textFieldStyle(.plain)
                        .font(.ui(.footnote))
                        .frame(width: 140)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(Color.uiCanvas)
                        .cornerRadius(UIRadius.xs)
                        .overlay(RoundedRectangle(cornerRadius: UIRadius.xs)
                            .stroke(rejected ? Color.uiEmber : Color.uiHairline, lineWidth: 1))
                        .onSubmit { submitVariant(lang) }
                        .onExitCommand { addingLanguage = nil }
                        .onChange(of: newVariant) { _ in rejected = false }
                } else {
                    Button(action: {
                        newVariant = ""
                        rejected = false
                        addingLanguage = lang
                    }) {
                        Text("+ вариант")
                            .font(.ui(.footnote))
                            .foregroundColor(.uiMidGray)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func submitVariant(_ lang: DictionaryLanguage) {
        guard let variant = DictionaryScreenLogic.typedVariant(
            newVariant, spelling: entry.spelling, language: lang,
            existing: entry.variants[lang] ?? [], checker: SpellCommonWordChecker.shared
        ) else {
            rejected = true
            return
        }
        addVariant(variant, language: lang)
        newVariant = ""
        addingLanguage = nil
    }

    private func addVariant(_ variant: String, language lang: DictionaryLanguage) {
        guard let current = store.userEntries.first(where: { $0.id == entry.id }) else { return }
        var updated = current
        var list = updated.variants[lang] ?? []
        guard !list.contains(where: { $0.lowercased() == variant.lowercased() }) else { return }
        list.append(variant)
        updated.variants[lang] = list
        store.updateEntry(updated)
    }
}

// MARK: - Оформление разделов

extension View {
    /// Блок раздела словаря: светлая подложка с тонкой рамкой.
    func dictionarySectionBox() -> some View {
        self
            .background(Color.uiPaper)
            .cornerRadius(UIRadius.md)
            .overlay(RoundedRectangle(cornerRadius: UIRadius.md).stroke(Color.uiHairline, lineWidth: 1))
    }
}
