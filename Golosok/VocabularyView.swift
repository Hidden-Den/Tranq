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

enum TermFilter: String, CaseIterable {
    case all = "all"
    case manual = "manual"
    case auto = "auto"

    var title: String {
        switch self {
        case .all: return String(localized: "Все")
        case .manual: return String(localized: "Вручную")
        case .auto: return String(localized: "Изученные")
        }
    }
}

struct VocabularyView: View {
    @ObservedObject var engine = PersonalizationEngine.shared
    @ObservedObject var settings = VoiceIntelligenceSettings.shared

    @State private var selectedTab: VocabularyTab = .terms
    @State private var termSearchQuery: String = ""
    @State private var termFilter: TermFilter = .all
    @State private var newTermInput: String = ""

    @State private var ruleSearchQuery: String = ""
    @State private var newRulePattern: String = ""
    @State private var newRuleReplacement: String = ""

    @State private var showingResetAlert: Bool = false

    private var filteredTerms: [LearnedTerm] {
        let list = engine.learnedTerms
        return list.filter { item in
            let matchesFilter: Bool
            switch termFilter {
            case .all: matchesFilter = true
            case .manual: matchesFilter = item.isManual
            case .auto: matchesFilter = !item.isManual
            }
            guard matchesFilter else { return false }
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
        if ruleSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return list.sorted { $0.count > $1.count }
        }
        return list.filter {
            $0.pattern.localizedCaseInsensitiveContains(ruleSearchQuery) ||
            $0.replacement.localizedCaseInsensitiveContains(ruleSearchQuery)
        }.sorted { $0.count > $1.count }
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
                message: Text("Все автоматически изученные термины и правила правок будут сброшены к начальным значениям."),
                primaryButton: .destructive(Text("Очистить")) {
                    engine.resetMemory()
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
                    .font(UIStyleFont.display(size: 18, weight: .bold))
                    .foregroundColor(.uiInk)
                Text("Справочник терминов, автозамены и промпт модели")
                    .font(UIStyleFont.body(size: 11, weight: .regular))
                    .foregroundColor(.uiMidGray)
            }

            Spacer()

            HStack(spacing: 12) {
                // Переключатель адаптивного обучения
                HStack(spacing: 8) {
                    Text("Адаптивное обучение")
                        .font(UIStyleFont.body(size: 12, weight: .medium))
                        .foregroundColor(.uiInk)
                    Toggle(String(localized: "Адаптивное обучение"), isOn: $engine.isLearningEnabled)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#10B981")))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.uiPaper)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))

                // Кнопка очистки памяти
                if !engine.learnedTerms.isEmpty || !engine.correctionRules.isEmpty {
                    Button(action: { showingResetAlert = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.uiMidGray)
                            .frame(width: 30, height: 30)
                            .background(Color.uiPaper)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
                    }
                    .buttonStyle(TactileButtonStyle())
                    .help(String(localized: "Очистить память обучения"))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color.uiCanvas)
        .overlay(Divider().background(Color.uiHairline), alignment: .bottom)
    }

    // MARK: - Переключатель разделов (Вкладки)

    private var tabSegmentBar: some View {
        HStack(spacing: 8) {
            ForEach(VocabularyTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(tab.title)
                            .font(UIStyleFont.body(size: 12, weight: isSelected ? .semibold : .medium))

                        // Счетчик для вкладок
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
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
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
            .font(UIStyleFont.body(size: 10, weight: .semibold))
            .foregroundColor(isSelected ? .uiInk : .uiMidGray)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(isSelected ? Color.uiCanvas : Color.uiPaper)
            .cornerRadius(10)
    }

    // MARK: - Область контента

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

    // MARK: - Вкладка 1: Справочник терминов

    private var termsDirectoryTab: some View {
        VStack(spacing: 12) {
            // Панель поиска, добавления и фильтров
            HStack(spacing: 10) {
                // Поле поиска
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(.uiMidGray)
                    TextField("Поиск терминов", text: $termSearchQuery)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(UIStyleFont.body(size: 12, weight: .regular))
                        .foregroundColor(.uiInk)
                    if !termSearchQuery.isEmpty {
                        Button(action: { termSearchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.uiMidGray)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.uiPaper)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.uiHairline, lineWidth: 1))
                .frame(maxWidth: 240)

                // Фильтры
                HStack(spacing: 4) {
                    ForEach(TermFilter.allCases, id: \.self) { f in
                        let isActive = termFilter == f
                        Button(action: { termFilter = f }) {
                            Text(f.title)
                                .font(UIStyleFont.body(size: 11, weight: isActive ? .semibold : .regular))
                                .foregroundColor(isActive ? .uiInk : .uiMidGray)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isActive ? Color.uiPaper : Color.clear)
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(isActive ? Color.uiHairline : Color.clear, lineWidth: 1)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }

                Spacer()

                // Поле быстрого добавления термина
                HStack(spacing: 6) {
                    TextField("Новый термин", text: $newTermInput)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(UIStyleFont.body(size: 12, weight: .regular))
                        .foregroundColor(.uiInk)
                        .frame(width: 140)
                        .onSubmit { addNewTerm() }

                    Button(action: addNewTerm) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.uiInk)
                            .frame(width: 26, height: 26)
                            .background(Color.uiPaper)
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.uiHairline, lineWidth: 1))
                    }
                    .buttonStyle(TactileButtonStyle())
                    .disabled(newTermInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.uiPaper)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.uiHairline, lineWidth: 1))
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            // Список терминов (LazyVStack оптимизирован под 800+ записей)
            ScrollView {
                if filteredTerms.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "character.book.closed")
                            .font(.system(size: 28))
                            .foregroundColor(.uiMidGray)
                        Text(termSearchQuery.isEmpty ? "Список терминов пуст" : "Термины не найдены")
                            .font(UIStyleFont.body(size: 13, weight: .regular))
                            .foregroundColor(.uiMidGray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredTerms) { item in
                            HStack(alignment: .center, spacing: 12) {
                                Text(item.term)
                                    .font(UIStyleFont.body(size: 13, weight: .medium))
                                    .foregroundColor(.uiInk)

                                Spacer()

                                if item.isManual {
                                    Text("Вручную")
                                        .font(UIStyleFont.body(size: 10, weight: .medium))
                                        .foregroundColor(.uiMidGray)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.uiCanvas)
                                        .cornerRadius(6)
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.uiHairline, lineWidth: 1))
                                } else {
                                    Text("Авто • \(item.count)")
                                        .font(UIStyleFont.body(size: 10, weight: .medium))
                                        .foregroundColor(Color(hex: "#10B981"))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color(hex: "#10B981").opacity(0.1))
                                        .cornerRadius(6)
                                }

                                Button(action: { engine.removeTerm(item.term) }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.uiMidGray)
                                        .frame(width: 22, height: 22)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(PlainButtonStyle())
                                .help(String(localized: "Удалить термин"))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.uiPaper)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func addNewTerm() {
        let cleaned = newTermInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        engine.addManualTerm(cleaned)
        newTermInput = ""
    }

    // MARK: - Вкладка 2: Автозамены речи

    private var rulesDirectoryTab: some View {
        VStack(spacing: 12) {
            // Панель поиска и добавления правила
            HStack(spacing: 10) {
                // Поиск
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(.uiMidGray)
                    TextField("Поиск правил", text: $ruleSearchQuery)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(UIStyleFont.body(size: 12, weight: .regular))
                        .foregroundColor(.uiInk)
                    if !ruleSearchQuery.isEmpty {
                        Button(action: { ruleSearchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.uiMidGray)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.uiPaper)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.uiHairline, lineWidth: 1))
                .frame(maxWidth: 200)

                Spacer()

                // Добавление нового правила
                HStack(spacing: 6) {
                    TextField("Слышит", text: $newRulePattern)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(UIStyleFont.body(size: 12, weight: .regular))
                        .foregroundColor(.uiInk)
                        .frame(width: 90)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.uiMidGray)

                    TextField("Заменяет", text: $newRuleReplacement)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(UIStyleFont.body(size: 12, weight: .regular))
                        .foregroundColor(.uiInk)
                        .frame(width: 100)
                        .onSubmit { addNewRule() }

                    Button(action: addNewRule) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.uiInk)
                            .frame(width: 26, height: 26)
                            .background(Color.uiPaper)
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.uiHairline, lineWidth: 1))
                    }
                    .buttonStyle(TactileButtonStyle())
                    .disabled(newRulePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.uiPaper)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.uiHairline, lineWidth: 1))
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            // Список правил
            ScrollView {
                if filteredRules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.system(size: 28))
                            .foregroundColor(.uiMidGray)
                        Text(ruleSearchQuery.isEmpty ? "Правил автозамены пока нет" : "Правила не найдены")
                            .font(UIStyleFont.body(size: 13, weight: .regular))
                            .foregroundColor(.uiMidGray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredRules) { rule in
                            HStack(alignment: .center, spacing: 10) {
                                Text(rule.pattern)
                                    .font(UIStyleFont.body(size: 13, weight: .regular))
                                    .foregroundColor(.uiInk)

                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.uiMidGray)

                                Text(rule.replacement.isEmpty ? "удаление" : rule.replacement)
                                    .font(UIStyleFont.body(size: 13, weight: .medium))
                                    .foregroundColor(.uiInk)

                                Spacer()

                                Text("\(rule.count)")
                                    .font(UIStyleFont.body(size: 10, weight: .semibold))
                                    .foregroundColor(.uiMidGray)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.uiCanvas)
                                    .cornerRadius(6)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.uiHairline, lineWidth: 1))

                                Button(action: { engine.removeRule(id: rule.id) }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.uiMidGray)
                                        .frame(width: 22, height: 22)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(PlainButtonStyle())
                                .help(String(localized: "Удалить правило"))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.uiPaper)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func addNewRule() {
        let pClean = newRulePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let rClean = newRuleReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pClean.isEmpty else { return }
        engine.addManualRule(pattern: pClean, replacement: rClean)
        newRulePattern = ""
        newRuleReplacement = ""
    }

    // MARK: - Вкладка 3: Системный промпт модели

    private var promptEditorTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Инструкция для языковой модели")
                        .font(UIStyleFont.body(size: 13, weight: .medium))
                        .foregroundColor(.uiInk)
                    Text("Системный контекст, используемый при синтезе чистой мысли")
                        .font(UIStyleFont.body(size: 11, weight: .regular))
                        .foregroundColor(.uiMidGray)
                }

                Spacer()

                UIOutlineButton(title: "По умолчанию") {
                    settings.customSystemPrompt = VoiceIntelligenceSettings.defaultCustomPrompt
                }
            }

            TextEditor(text: $settings.customSystemPrompt)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(.uiInk)
                .lineSpacing(3)
                .padding(10)
                .background(Color.uiPaper)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))

            Spacer()
        }
        .padding(24)
    }
}
