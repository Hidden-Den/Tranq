import SwiftUI

enum VocabularyTab: String, CaseIterable, Identifiable {
    case terms = "terms"
    case rules = "rules"
    case prompt = "prompt"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terms: return String(localized: "Термины")
        case .rules: return String(localized: "Автозамены")
        case .prompt: return String(localized: "Системный промпт")
        }
    }

    var icon: String {
        switch self {
        case .terms: return "character.book.closed.fill"
        case .rules: return "arrow.2.squarepath"
        case .prompt: return "text.quote"
        }
    }
}

enum DomainCategory: String, CaseIterable, Identifiable {
    case all = "all"
    case it = "it"
    case management = "management"
    case business = "business"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "Все")
        case .it: return String(localized: "IT и разработка")
        case .management: return String(localized: "Менеджмент")
        case .business: return String(localized: "Бизнес и HR")
        case .custom: return String(localized: "Мои")
        }
    }

    var badgeTitle: String {
        switch self {
        case .all: return ""
        case .it: return "IT"
        case .management: return "Менеджмент"
        case .business: return "Бизнес"
        case .custom: return "Моё"
        }
    }

    var color: Color {
        switch self {
        case .all: return .uiMidGray
        case .it: return Color.uiInfo
        case .management: return Color.uiAIDeep
        case .business: return Color.uiAmber
        case .custom: return Color.uiSuccess
        }
    }
}

struct VocabularyView: View {
    @ObservedObject var engine = PersonalizationEngine.shared
    @ObservedObject var settings = VoiceIntelligenceSettings.shared

    @State private var selectedTab: VocabularyTab = .terms
    @State private var selectedCategory: DomainCategory = .all

    @State private var termSearchQuery: String = ""
    @State private var newTermInput: String = ""
    @State private var editingTermId: String? = nil
    @State private var editingTermText: String = ""

    @State private var ruleSearchQuery: String = ""
    @State private var newRulePattern: String = ""
    @State private var newRuleReplacement: String = ""
    @State private var editingRuleId: UUID? = nil
    @State private var editingRulePattern: String = ""
    @State private var editingRuleReplacement: String = ""

    @State private var showingResetAlert: Bool = false

    private var filteredTerms: [LearnedTerm] {
        let list = engine.learnedTerms
        return list.filter { item in
            let matchesCategory: Bool
            switch selectedCategory {
            case .all: matchesCategory = true
            case .it: matchesCategory = item.category == "it"
            case .management: matchesCategory = item.category == "management"
            case .business: matchesCategory = item.category == "business"
            case .custom: matchesCategory = item.category == "custom" || item.category == nil
            }
            guard matchesCategory else { return false }
            if termSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return item.term.localizedCaseInsensitiveContains(termSearchQuery)
        }.sorted { lhs, rhs in
            if lhs.isManual != rhs.isManual { return lhs.isManual }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.term.localizedCompare(rhs.term) == .orderedAscending
        }
    }

    private var filteredRules: [CorrectionRule] {
        let list = engine.correctionRules
        return list.filter { rule in
            let matchesCategory: Bool
            switch selectedCategory {
            case .all: matchesCategory = true
            case .it: matchesCategory = rule.category == "it"
            case .management: matchesCategory = rule.category == "management"
            case .business: matchesCategory = rule.category == "business"
            case .custom: matchesCategory = rule.category == "custom" || rule.category == nil
            }
            guard matchesCategory else { return false }
            if ruleSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return rule.pattern.localizedCaseInsensitiveContains(ruleSearchQuery) ||
                   rule.replacement.localizedCaseInsensitiveContains(ruleSearchQuery)
        }.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.pattern.localizedCompare(rhs.pattern) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            tabSegmentBar
            contentArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.uiCanvas)
        .alert(isPresented: $showingResetAlert) {
            Alert(
                title: Text("Очистить память обучения"),
                message: Text("Все изученные термины и правила правок будут сброшены к начальным значениям встроенного справочника."),
                primaryButton: .destructive(Text("Очистить")) {
                    engine.resetMemory(restoreBuiltins: true)
                },
                secondaryButton: .cancel(Text("Отмена"))
            )
        }
    }

    // MARK: - Верхняя панель заголовка

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Словарь и обучение")
                    .font(.ui(.headline, weight: .bold))
                    .foregroundColor(.uiInk)
                Text("Встроенный справочник IT и бизнеса, автозамены речи и системный промпт")
                    .font(.ui(.caption))
                    .foregroundColor(.uiMidGray)
            }

            Spacer()

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text("Адаптивное обучение")
                        .font(.ui(.footnote, weight: .medium))
                        .foregroundColor(.uiInk)
                    Toggle(String(localized: "Адаптивное обучение"), isOn: $engine.isLearningEnabled)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.uiPaper)
                .cornerRadius(UIRadius.sm)
                .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))

                if !engine.learnedTerms.isEmpty || !engine.correctionRules.isEmpty {
                    Button(action: { showingResetAlert = true }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.ui(.caption, weight: .medium))
                            .foregroundColor(.uiMidGray)
                            .frame(width: 30, height: 30)
                            .background(Color.uiPaper)
                            .cornerRadius(UIRadius.sm)
                            .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
                    }
                    .buttonStyle(TactileButtonStyle())
                    .help(String(localized: "Сбросить память к заводскому справочнику"))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color.uiCanvas)
        .overlay(Divider().background(Color.uiHairline), alignment: .bottom)
    }

    // MARK: - Вкладки разделов

    private var tabSegmentBar: some View {
        HStack(spacing: 8) {
            ForEach(VocabularyTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedTab = tab
                        editingTermId = nil
                        editingRuleId = nil
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.ui(.caption, weight: .semibold))
                        Text(tab.title)
                            .font(.ui(.footnote, weight: isSelected ? .semibold : .medium))

                        if tab == .terms {
                            badgePill(text: "\(engine.learnedTerms.count)", isSelected: isSelected)
                        } else if tab == .rules {
                            badgePill(text: "\(engine.correctionRules.count)", isSelected: isSelected)
                        }
                    }
                    .foregroundColor(isSelected ? .uiInk : .uiMidGray)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(isSelected ? Color.uiPaper : Color.clear)
                    .cornerRadius(UIRadius.sm)
                    .overlay(
                        RoundedRectangle(cornerRadius: UIRadius.sm)
                            .stroke(isSelected ? Color.uiHairline : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(TactileButtonStyle())
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color.uiCanvas)
        .overlay(Divider().background(Color.uiHairline), alignment: .bottom)
    }

    private func badgePill(text: String, isSelected: Bool) -> some View {
        Text(text)
            .font(.ui(.micro, weight: .semibold))
            .foregroundColor(isSelected ? .uiInk : .uiMidGray)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(isSelected ? Color.uiCanvas : Color.uiPaper)
            .cornerRadius(UIRadius.md)
    }

    // MARK: - Контент

    @ViewBuilder
    private var contentArea: some View {
        switch selectedTab {
        case .terms:
            termsDirectoryTab
        case .rules:
            rulesDirectoryTab
        case .prompt:
            promptEditorTab
        }
    }

    // MARK: - Вкладка 1: Термины

    private var termsDirectoryTab: some View {
        VStack(spacing: 12) {
            // Панель категорий, поиска и добавления
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    // Поиск
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.ui(.caption))
                            .foregroundColor(.uiMidGray)
                        TextField("Поиск терминов", text: $termSearchQuery)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.ui(.footnote))
                            .foregroundColor(.uiInk)
                        if !termSearchQuery.isEmpty {
                            Button(action: { termSearchQuery = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.ui(.micro))
                                    .foregroundColor(.uiMidGray)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.uiPaper)
                    .cornerRadius(UIRadius.sm)
                    .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
                    .frame(maxWidth: 240)

                    Spacer()

                    // Добавление термина
                    HStack(spacing: 6) {
                        TextField("Новый термин", text: $newTermInput)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.ui(.footnote))
                            .foregroundColor(.uiInk)
                            .frame(width: 140)
                            .onSubmit { addNewTerm() }

                        Button(action: addNewTerm) {
                            Image(systemName: "plus")
                                .font(.ui(.caption, weight: .bold))
                                .foregroundColor(.uiInk)
                                .frame(width: 26, height: 26)
                                .background(Color.uiPaper)
                                .cornerRadius(UIRadius.sm)
                                .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
                        }
                        .buttonStyle(TactileButtonStyle())
                        .disabled(newTermInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.uiPaper)
                    .cornerRadius(UIRadius.sm)
                    .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
                }

                // Категории
                HStack(spacing: 4) {
                    ForEach(DomainCategory.allCases) { cat in
                        let isActive = selectedCategory == cat
                        Button(action: { selectedCategory = cat }) {
                            Text(cat.title)
                                .font(.ui(.caption, weight: isActive ? .semibold : .regular))
                                .foregroundColor(isActive ? .uiInk : .uiMidGray)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isActive ? Color.uiPaper : Color.clear)
                                .cornerRadius(UIRadius.sm)
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.sm)
                                        .stroke(isActive ? Color.uiHairline : Color.clear, lineWidth: 1)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            // Список терминов
            ScrollView {
                if filteredTerms.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "character.book.closed")
                            .font(.ui(.display))
                            .foregroundColor(.uiMidGray)
                        Text(termSearchQuery.isEmpty ? "В этой категории нет терминов" : "Термины не найдены")
                            .font(.ui(.body))
                            .foregroundColor(.uiMidGray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredTerms) { item in
                            termRow(item: item)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func termRow(item: LearnedTerm) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if editingTermId == item.id {
                TextField("Термин", text: $editingTermText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.ui(.body, weight: .medium))
                    .foregroundColor(.uiInk)
                    .padding(4)
                    .background(Color.uiCanvas)
                    .cornerRadius(UIRadius.xs)
                    .overlay(RoundedRectangle(cornerRadius: UIRadius.xs).stroke(Color.uiInfo, lineWidth: 1))
                    .onSubmit {
                        saveEditedTerm(oldTerm: item.term)
                    }

                Spacer()

                Button(action: { saveEditedTerm(oldTerm: item.term) }) {
                    Image(systemName: "checkmark")
                        .font(.ui(.micro, weight: .bold))
                        .foregroundColor(Color.uiSuccess)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PlainButtonStyle())
                .help(String(localized: "Сохранить"))

                Button(action: { editingTermId = nil }) {
                    Image(systemName: "xmark")
                        .font(.ui(.micro, weight: .bold))
                        .foregroundColor(.uiMidGray)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PlainButtonStyle())
                .help(String(localized: "Отмена"))
            } else {
                Text(item.term)
                    .font(.ui(.body, weight: .medium))
                    .foregroundColor(.uiInk)

                Spacer()

                categoryBadge(for: item.category, isManual: item.isManual, count: item.count)

                Button(action: {
                    editingTermId = item.id
                    editingTermText = item.term
                }) {
                    Image(systemName: "pencil")
                        .font(.ui(.micro, weight: .medium))
                        .foregroundColor(.uiMidGray)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .help(String(localized: "Редактировать термин"))

                Button(action: { engine.removeTerm(item.term) }) {
                    Image(systemName: "trash")
                        .font(.ui(.micro, weight: .medium))
                        .foregroundColor(.uiMidGray)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .help(String(localized: "Удалить термин"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.uiPaper)
        .cornerRadius(UIRadius.sm)
        .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
    }

    private func saveEditedTerm(oldTerm: String) {
        let cleaned = editingTermText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            engine.updateTerm(oldTerm: oldTerm, newTerm: cleaned)
        }
        editingTermId = nil
    }

    private func addNewTerm() {
        let cleaned = newTermInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        engine.addManualTerm(cleaned, category: selectedCategory == .all ? "custom" : selectedCategory.rawValue)
        newTermInput = ""
    }

    // MARK: - Вкладка 2: Автозамены речи

    private var rulesDirectoryTab: some View {
        VStack(spacing: 12) {
            // Поиск, категории и добавление
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.ui(.caption))
                            .foregroundColor(.uiMidGray)
                        TextField("Поиск правил", text: $ruleSearchQuery)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.ui(.footnote))
                            .foregroundColor(.uiInk)
                        if !ruleSearchQuery.isEmpty {
                            Button(action: { ruleSearchQuery = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.ui(.micro))
                                    .foregroundColor(.uiMidGray)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.uiPaper)
                    .cornerRadius(UIRadius.sm)
                    .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
                    .frame(maxWidth: 200)

                    Spacer()

                    // Добавление правила
                    HStack(spacing: 6) {
                        TextField("Слышит", text: $newRulePattern)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.ui(.footnote))
                            .foregroundColor(.uiInk)
                            .frame(width: 90)

                        Image(systemName: "arrow.right")
                            .font(.ui(.micro, weight: .semibold))
                            .foregroundColor(.uiMidGray)

                        TextField("Заменяет", text: $newRuleReplacement)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.ui(.footnote))
                            .foregroundColor(.uiInk)
                            .frame(width: 100)
                            .onSubmit { addNewRule() }

                        Button(action: addNewRule) {
                            Image(systemName: "plus")
                                .font(.ui(.caption, weight: .bold))
                                .foregroundColor(.uiInk)
                                .frame(width: 26, height: 26)
                                .background(Color.uiPaper)
                                .cornerRadius(UIRadius.sm)
                                .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
                        }
                        .buttonStyle(TactileButtonStyle())
                        .disabled(newRulePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.uiPaper)
                    .cornerRadius(UIRadius.sm)
                    .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
                }

                // Категории
                HStack(spacing: 4) {
                    ForEach(DomainCategory.allCases) { cat in
                        let isActive = selectedCategory == cat
                        Button(action: { selectedCategory = cat }) {
                            Text(cat.title)
                                .font(.ui(.caption, weight: isActive ? .semibold : .regular))
                                .foregroundColor(isActive ? .uiInk : .uiMidGray)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isActive ? Color.uiPaper : Color.clear)
                                .cornerRadius(UIRadius.sm)
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.sm)
                                        .stroke(isActive ? Color.uiHairline : Color.clear, lineWidth: 1)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            // Список правил
            ScrollView {
                if filteredRules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.ui(.display))
                            .foregroundColor(.uiMidGray)
                        Text(ruleSearchQuery.isEmpty ? "В этой категории нет правил автозамены" : "Правила не найдены")
                            .font(.ui(.body))
                            .foregroundColor(.uiMidGray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredRules) { rule in
                            ruleRow(rule: rule)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func ruleRow(rule: CorrectionRule) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if editingRuleId == rule.id {
                TextField("Слышит", text: $editingRulePattern)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.ui(.footnote))
                    .foregroundColor(.uiInk)
                    .frame(width: 110)
                    .padding(4)
                    .background(Color.uiCanvas)
                    .cornerRadius(UIRadius.xs)
                    .overlay(RoundedRectangle(cornerRadius: UIRadius.xs).stroke(Color.uiInfo, lineWidth: 1))

                Image(systemName: "arrow.right")
                    .font(.ui(.micro, weight: .semibold))
                    .foregroundColor(.uiMidGray)

                TextField("Заменяет", text: $editingRuleReplacement)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.ui(.footnote, weight: .medium))
                    .foregroundColor(.uiInk)
                    .frame(width: 110)
                    .padding(4)
                    .background(Color.uiCanvas)
                    .cornerRadius(UIRadius.xs)
                    .overlay(RoundedRectangle(cornerRadius: UIRadius.xs).stroke(Color.uiInfo, lineWidth: 1))
                    .onSubmit {
                        saveEditedRule(id: rule.id)
                    }

                Spacer()

                Button(action: { saveEditedRule(id: rule.id) }) {
                    Image(systemName: "checkmark")
                        .font(.ui(.micro, weight: .bold))
                        .foregroundColor(Color.uiSuccess)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PlainButtonStyle())
                .help(String(localized: "Сохранить"))

                Button(action: { editingRuleId = nil }) {
                    Image(systemName: "xmark")
                        .font(.ui(.micro, weight: .bold))
                        .foregroundColor(.uiMidGray)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PlainButtonStyle())
                .help(String(localized: "Отмена"))
            } else {
                Text(rule.pattern)
                    .font(.ui(.body))
                    .foregroundColor(.uiInk)

                Image(systemName: "arrow.right")
                    .font(.ui(.micro, weight: .semibold))
                    .foregroundColor(.uiMidGray)

                Text(rule.replacement.isEmpty ? "удаление" : rule.replacement)
                    .font(.ui(.body, weight: .medium))
                    .foregroundColor(.uiInk)

                Spacer()

                categoryBadge(for: rule.category, isManual: rule.source != .edit, count: rule.count)

                Button(action: {
                    editingRuleId = rule.id
                    editingRulePattern = rule.pattern
                    editingRuleReplacement = rule.replacement
                }) {
                    Image(systemName: "pencil")
                        .font(.ui(.micro, weight: .medium))
                        .foregroundColor(.uiMidGray)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .help(String(localized: "Редактировать правило"))

                Button(action: { engine.removeRule(id: rule.id) }) {
                    Image(systemName: "trash")
                        .font(.ui(.micro, weight: .medium))
                        .foregroundColor(.uiMidGray)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .help(String(localized: "Удалить правило"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.uiPaper)
        .cornerRadius(UIRadius.sm)
        .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
    }

    private func saveEditedRule(id: UUID) {
        let p = editingRulePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = editingRuleReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty {
            engine.updateRule(id: id, pattern: p, replacement: r)
        }
        editingRuleId = nil
    }

    private func addNewRule() {
        let pClean = newRulePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let rClean = newRuleReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pClean.isEmpty else { return }
        engine.addManualRule(
            pattern: pClean,
            replacement: rClean,
            category: selectedCategory == .all ? "custom" : selectedCategory.rawValue
        )
        newRulePattern = ""
        newRuleReplacement = ""
    }

    // MARK: - Вспомогательные элементы

    private func categoryBadge(for category: String?, isManual: Bool, count: Int) -> some View {
        HStack(spacing: 4) {
            if let cat = category, let domain = DomainCategory(rawValue: cat), domain != .all {
                Text(domain.badgeTitle)
                    .font(.ui(.micro, weight: .semibold))
                    .foregroundColor(domain.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(domain.color.opacity(0.12))
                    .cornerRadius(UIRadius.xs)
            } else if !isManual {
                Text("Авто • \(count)")
                    .font(.ui(.micro, weight: .semibold))
                    .foregroundColor(Color.uiSuccess)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.uiSuccess.opacity(0.12))
                    .cornerRadius(UIRadius.xs)
            } else {
                Text("Моё")
                    .font(.ui(.micro, weight: .semibold))
                    .foregroundColor(.uiMidGray)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.uiCanvas)
                    .cornerRadius(UIRadius.xs)
                    .overlay(RoundedRectangle(cornerRadius: UIRadius.xs).stroke(Color.uiHairline, lineWidth: 1))
            }
        }
    }

    // MARK: - Вкладка 3: Системный промпт модели

    private var promptEditorTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Инструкция для языковой модели")
                        .font(.ui(.body, weight: .medium))
                        .foregroundColor(.uiInk)
                    Text("Системный контекст, используемый при синтезе чистой мысли")
                        .font(.ui(.caption))
                        .foregroundColor(.uiMidGray)
                }

                Spacer()

                UIOutlineButton(title: "По умолчанию") {
                    settings.customSystemPrompt = VoiceIntelligenceSettings.defaultCustomPrompt
                }
            }

            TextEditor(text: $settings.customSystemPrompt)
                .font(.ui(.footnote, design: .monospaced))
                .foregroundColor(.uiInk)
                .lineSpacing(3)
                .padding(10)
                .background(Color.uiPaper)
                .cornerRadius(UIRadius.sm)
                .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))

            Spacer()
        }
        .padding(24)
    }
}
