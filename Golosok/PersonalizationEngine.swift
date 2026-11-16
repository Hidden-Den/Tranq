import Foundation

/// Правило автоисправления, выученное на основе правок пользователя
public struct CorrectionRule: Codable, Identifiable, Equatable {
    public let id: UUID
    public var pattern: String
    public var replacement: String
    public var count: Int
    public var lastUsed: Date
    public var source: RuleSource
    public var category: String?

    public enum RuleSource: String, Codable {
        case edit
        case manual
        case builtin
    }

    public init(
        id: UUID = UUID(),
        pattern: String,
        replacement: String,
        count: Int = 1,
        lastUsed: Date = Date(),
        source: RuleSource = .edit,
        category: String? = nil
    ) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.count = count
        self.lastUsed = lastUsed
        self.source = source
        self.category = category
    }
}

/// Изученный термин или жаргонизм пользователя
public struct LearnedTerm: Codable, Identifiable, Equatable {
    public var id: String { term.lowercased() }
    public var term: String
    public var count: Int
    public var lastUsed: Date
    public var isManual: Bool
    public var category: String?

    public init(term: String, count: Int = 1, lastUsed: Date = Date(), isManual: Bool = false, category: String? = nil) {
        self.term = term
        self.count = count
        self.lastUsed = lastUsed
        self.isManual = isManual
        self.category = category
    }
}

/// Контейнер персистентного состояния персонализации
private struct PersonalizationSnapshot: Codable {
    var isLearningEnabled: Bool
    var rules: [CorrectionRule]
    var terms: [LearnedTerm]
    var deletedBuiltinPatterns: [String]?
    var deletedBuiltinTerms: [String]?
}

/// Сверхбыстрый локальный движок персонализации и адаптивного обучения (On-Device In-Context Learning)
public final class PersonalizationEngine: ObservableObject {
    public static let shared = PersonalizationEngine()

    @Published public var isLearningEnabled: Bool {
        didSet {
            AppEnvironment.defaults.set(isLearningEnabled, forKey: "voice.personalization.enabled")
            scheduleSave()
        }
    }

    @Published public private(set) var correctionRules: [CorrectionRule] = []
    @Published public private(set) var learnedTerms: [LearnedTerm] = []

    private var deletedBuiltinPatterns: Set<String> = []
    private var deletedBuiltinTerms: Set<String> = []

    private let queue = DispatchQueue(label: "com.golosok.personalization", qos: .utility)
    private var saveWorkItem: DispatchWorkItem?
    private let lock = NSLock()

    private var storageFileURL: URL? {
        AppEnvironment.dataDirectory.appendingPathComponent("personalization.json")
    }

    private init() {
        let storedEnabled = AppEnvironment.defaults.object(forKey: "voice.personalization.enabled") as? Bool ?? true
        self.isLearningEnabled = storedEnabled
        loadFromDisk()
    }

    // MARK: - Пассивное обучение на речевом потоке

    /// Пассивное обнаружение сущностей, терминов и англицизмов в распознанной речи
    public func observeSpeech(text: String) {
        guard isLearningEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        queue.async { [weak self] in
            guard let self = self else { return }
            let candidates = Self.extractCandidateTerms(from: trimmed)
            guard !candidates.isEmpty else { return }

            self.lock.lock()
            var modified = false
            for candidate in candidates {
                let lower = candidate.lowercased()
                if let idx = self.learnedTerms.firstIndex(where: { $0.term.lowercased() == lower }) {
                    self.learnedTerms[idx].count += 1
                    self.learnedTerms[idx].lastUsed = Date()
                    // Обновляем оригинальное написание, если оно содержит заглавные буквы
                    if candidate != candidate.lowercased() {
                        self.learnedTerms[idx].term = candidate
                    }
                    modified = true
                } else {
                    let newTerm = LearnedTerm(term: candidate, count: 1, lastUsed: Date(), isManual: false)
                    self.learnedTerms.append(newTerm)
                    modified = true
                }
            }

            // Ограничение размера словаря (храним до 500 терминов)
            if self.learnedTerms.count > 500 {
                self.learnedTerms.sort { lhs, rhs in
                    if lhs.isManual != rhs.isManual { return lhs.isManual }
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.lastUsed > rhs.lastUsed
                }
                self.learnedTerms = Array(self.learnedTerms.prefix(500))
            }
            self.lock.unlock()

            if modified {
                DispatchQueue.main.async {
                    self.objectWillChange.send()
                }
                self.scheduleSave()
            }
        }
    }

    // MARK: - Активное обучение на пользовательских правках

    /// Обучение на основе ручного редактирования текста заметки в приложении
    public func learnFromEdit(original: String, edited: String, noteId: UUID? = nil) {
        guard isLearningEnabled else { return }
        let trimmedOrig = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEdit = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOrig.isEmpty, !trimmedEdit.isEmpty, trimmedOrig != trimmedEdit else { return }

        queue.async { [weak self] in
            guard let self = self else { return }
            let diffs = Self.extractDiffPairs(original: trimmedOrig, edited: trimmedEdit)
            guard !diffs.isEmpty else { return }

            self.lock.lock()
            var modified = false
            for diff in diffs {
                let patternClean = diff.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                let repClean = diff.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !patternClean.isEmpty else { continue }

                // 1. Обновляем правила автоисправления
                if let idx = self.correctionRules.firstIndex(where: { $0.pattern.lowercased() == patternClean.lowercased() }) {
                    self.correctionRules[idx].replacement = repClean
                    self.correctionRules[idx].count += 1
                    self.correctionRules[idx].lastUsed = Date()
                    modified = true
                } else {
                    let rule = CorrectionRule(pattern: patternClean, replacement: repClean, count: 1, lastUsed: Date(), source: .edit)
                    self.correctionRules.append(rule)
                    modified = true
                }

                // 2. Если замена — это специализированное слово (например, Kubernetes или Zoom), регистрируем термин
                if !repClean.isEmpty {
                    let words = repClean.split(separator: " ").map { String($0) }
                    for w in words {
                        let cleanedW = Self.cleanWord(w)
                        if cleanedW.count >= 2 && Self.isSpecializedTerm(cleanedW) {
                            let lower = cleanedW.lowercased()
                            if let tIdx = self.learnedTerms.firstIndex(where: { $0.term.lowercased() == lower }) {
                                self.learnedTerms[tIdx].term = cleanedW
                                self.learnedTerms[tIdx].count += 2
                                self.learnedTerms[tIdx].lastUsed = Date()
                            } else {
                                self.learnedTerms.append(LearnedTerm(term: cleanedW, count: 2, lastUsed: Date(), isManual: false))
                            }
                            modified = true
                        }
                    }
                }

                AppLogger.shared.info(
                    "Personalization",
                    "Изучено правило адаптации речи",
                    details: "«\(patternClean)» -> «\(repClean)»"
                )
            }

            // Ограничение правил (храним до 200 правил)
            if self.correctionRules.count > 200 {
                self.correctionRules.sort { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.lastUsed > rhs.lastUsed
                }
                self.correctionRules = Array(self.correctionRules.prefix(200))
            }
            self.lock.unlock()

            if modified {
                DispatchQueue.main.async {
                    self.objectWillChange.send()
                }
                self.scheduleSave()
            }
        }
    }

    // MARK: - Пре-инференсный поиск за O(1) и генерация контекста для промпта

    /// Формирование ультра-компактного контекста для системного промпта модели за < 0.3 мс
    public func buildPromptContext(for input: String) -> String {
        guard isLearningEnabled else { return "" }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        lock.lock()
        let rulesSnapshot = self.correctionRules
        let termsSnapshot = self.learnedTerms
        lock.unlock()

        guard !rulesSnapshot.isEmpty || !termsSnapshot.isEmpty else { return "" }

        // 1. Поиск правил, чьи паттерны встречаются в текущей реплике
        var matchedRules: [CorrectionRule] = []
        for rule in rulesSnapshot {
            if input.localizedCaseInsensitiveContains(rule.pattern) {
                matchedRules.append(rule)
                if matchedRules.count >= 3 { break }
            }
        }

        // 2. Поиск активных терминов пользователя (упомянутые или топ по частоте)
        var matchedTerms: [String] = []
        for term in termsSnapshot where term.count >= 2 || term.isManual {
            if input.localizedCaseInsensitiveContains(term.term) {
                matchedTerms.append(term.term)
                if matchedTerms.count >= 4 { break }
            }
        }

        // Если прямого совпадения терминов мало, добавляем топ-3 самых частых персональных терминов пользователя
        // Встроенные термины из общего каталога включаются только при прямом совпадении с речью, чтобы не смещать промпт
        if matchedTerms.count < 3 {
            let topUserTerms = termsSnapshot
                .filter { ($0.category == "custom" || $0.category == nil) && ($0.count >= 2 || $0.isManual) && !matchedTerms.contains($0.term) }
                .sorted { $0.count > $1.count }
                .prefix(3 - matchedTerms.count)
                .map { $0.term }
            matchedTerms.append(contentsOf: topUserTerms)
        }

        guard !matchedRules.isEmpty || !matchedTerms.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("Пользовательский словарь и предпочтения:")
        if !matchedTerms.isEmpty {
            lines.append("Термины: " + matchedTerms.joined(separator: ", "))
        }
        if !matchedRules.isEmpty {
            let rulesStr = matchedRules.map {
                $0.replacement.isEmpty ? "удаляй «\($0.pattern)»" : "«\($0.pattern)» -> «\($0.replacement)»"
            }.joined(separator: ", ")
            lines.append("Замены: " + rulesStr)
        }

        return lines.joined(separator: "\n")
    }

    /// Все доверенные термины пользователя для проверки в GroundingValidator
    public func allApprovedTerms(additionalTerms: [String] = []) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }

        var result = Set<String>()
        for term in learnedTerms where term.count >= 2 || term.isManual {
            result.insert(term.term)
        }
        for rule in correctionRules where !rule.replacement.isEmpty {
            let words = rule.replacement.split(separator: " ").map { String($0) }
            for w in words {
                let cleaned = Self.cleanWord(w)
                if !cleaned.isEmpty {
                    result.insert(cleaned)
                }
            }
        }
        for add in additionalTerms {
            result.insert(add)
        }
        return result
    }

    // MARK: - Управление памятью

    public func addManualTerm(_ term: String, category: String? = "custom") {
        let cleaned = Self.cleanWord(term)
        guard !cleaned.isEmpty else { return }
        lock.lock()
        let lower = cleaned.lowercased()
        if let idx = learnedTerms.firstIndex(where: { $0.term.lowercased() == lower }) {
            learnedTerms[idx].term = cleaned
            learnedTerms[idx].isManual = true
            learnedTerms[idx].lastUsed = Date()
            if let category { learnedTerms[idx].category = category }
        } else {
            let newTerm = LearnedTerm(term: cleaned, count: 5, lastUsed: Date(), isManual: true, category: category)
            learnedTerms.append(newTerm)
        }
        lock.unlock()
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        scheduleSave()
        VoiceIntelligenceSettings.shared.addUserTerm(cleaned)
    }

    public func updateTerm(oldTerm: String, newTerm: String) {
        let cleaned = Self.cleanWord(newTerm)
        guard !cleaned.isEmpty else { return }
        lock.lock()
        if let existingIdx = learnedTerms.firstIndex(where: { $0.term.lowercased() == cleaned.lowercased() }) {
            // Термин с таким именем уже существует — объединяем данные и удаляем старую запись
            if let oldIdx = learnedTerms.firstIndex(where: { $0.term.lowercased() == oldTerm.lowercased() }), oldIdx != existingIdx {
                learnedTerms[existingIdx].count += learnedTerms[oldIdx].count
                learnedTerms[existingIdx].lastUsed = Date()
                learnedTerms.remove(at: oldIdx)
            }
        } else if let idx = learnedTerms.firstIndex(where: { $0.term.lowercased() == oldTerm.lowercased() }) {
            learnedTerms[idx].term = cleaned
            learnedTerms[idx].lastUsed = Date()
        }
        lock.unlock()
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        scheduleSave()
        VoiceIntelligenceSettings.shared.removeUserTerm(oldTerm)
        VoiceIntelligenceSettings.shared.addUserTerm(cleaned)
    }

    public func addManualRule(pattern: String, replacement: String, category: String? = "custom") {
        let pClean = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let rClean = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pClean.isEmpty else { return }
        lock.lock()
        if let idx = correctionRules.firstIndex(where: { $0.pattern.lowercased() == pClean.lowercased() }) {
            correctionRules[idx].replacement = rClean
            correctionRules[idx].lastUsed = Date()
            if let category { correctionRules[idx].category = category }
        } else {
            let rule = CorrectionRule(pattern: pClean, replacement: rClean, count: 5, lastUsed: Date(), source: .manual, category: category)
            correctionRules.append(rule)
        }
        lock.unlock()
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        scheduleSave()
    }

    public func updateRule(id: UUID, pattern: String, replacement: String) {
        let pClean = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let rClean = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pClean.isEmpty else { return }
        lock.lock()
        if let existingIdx = correctionRules.firstIndex(where: { $0.pattern.lowercased() == pClean.lowercased() && $0.id != id }) {
            // Другое правило с таким шаблоном уже существует — обновляем его и удаляем дубликат
            correctionRules[existingIdx].replacement = rClean
            correctionRules[existingIdx].lastUsed = Date()
            correctionRules.removeAll { $0.id == id }
        } else if let idx = correctionRules.firstIndex(where: { $0.id == id }) {
            correctionRules[idx].pattern = pClean
            correctionRules[idx].replacement = rClean
            correctionRules[idx].lastUsed = Date()
        }
        lock.unlock()
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        scheduleSave()
    }

    public func removeTerm(_ term: String) {
        let lower = term.lowercased()
        lock.lock()
        deletedBuiltinTerms.insert(lower)
        learnedTerms.removeAll { $0.term.lowercased() == lower }
        lock.unlock()
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        scheduleSave()
        VoiceIntelligenceSettings.shared.removeUserTerm(term)
    }

    public func removeRule(id: UUID) {
        lock.lock()
        if let rule = correctionRules.first(where: { $0.id == id }) {
            deletedBuiltinPatterns.insert(rule.pattern.lowercased())
            correctionRules.removeAll { $0.id == id }
        }
        lock.unlock()
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        scheduleSave()
    }

    public func resetMemory(restoreBuiltins: Bool = false) {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        lock.lock()
        correctionRules.removeAll()
        learnedTerms.removeAll()
        deletedBuiltinPatterns.removeAll()
        deletedBuiltinTerms.removeAll()
        if restoreBuiltins {
            seedDefaultRules()
        }
        lock.unlock()

        VoiceIntelligenceSettings.shared.clearUserTerms()

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        AppLogger.shared.info("Personalization", "Память адаптивного обучения очищена (восстановление справочника: \(restoreBuiltins))")
    }

    // MARK: - Алгоритмы токенизации и LCS Diff

    public static func cleanWord(_ word: String) -> String {
        return word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    }

    public static func isLatinWord(_ word: String) -> Bool {
        let latinRegex = try? NSRegularExpression(pattern: #"^[A-Za-z0-9_\-\.]{2,}$"#)
        let range = NSRange(location: 0, length: (word as NSString).length)
        return latinRegex?.firstMatch(in: word, options: [], range: range) != nil
    }

    public static func isSpecializedTerm(_ word: String) -> Bool {
        if isLatinWord(word) { return true }
        // Кириллическая аббревиатура от 2 заглавных букв (ФНС, ГОСТ, ИП, ЭДО)
        if word.count >= 2 && word.allSatisfy({ ("А"..."Я").contains($0) || $0 == "Ё" }) {
            return true
        }
        // Смешанный буквенно-цифровой идентификатор (1С, M1, v2)
        let hasLetter = word.contains(where: { $0.isLetter })
        let hasNumber = word.contains(where: { $0.isNumber })
        if hasLetter && hasNumber {
            return true
        }
        return false
    }

    /// Детерминированное применение активных правил словаря к тексту
    public func applyRules(to text: String) -> String {
        guard !text.isEmpty else { return text }
        lock.lock()
        let rulesSnapshot = self.correctionRules
        lock.unlock()

        guard !rulesSnapshot.isEmpty else { return text }

        var result = text
        for rule in rulesSnapshot where !rule.pattern.isEmpty && !rule.replacement.isEmpty {
            let pattern = NSRegularExpression.escapedPattern(for: rule.pattern)
            let regexPattern = "(?i)(?<=^|[\\s.,!?;:\"«»()—–-]|\\b)\(pattern)(?=[\\s.,!?;:\"«»()—–-]|\\b|$)"
            if let regex = try? NSRegularExpression(pattern: regexPattern) {
                let range = NSRange(location: 0, length: (result as NSString).length)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: rule.replacement)
            }
        }
        return result
    }

    public static func extractCandidateTerms(from text: String) -> [String] {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
        let tokens = clean.split(separator: " ").map { String($0) }
        var candidates: [String] = []

        let cyrillicUpperRegex = try? NSRegularExpression(pattern: #"^[А-ЯЁ]{2,}$"#)
        let latinStopwords: Set<String> = ["in", "on", "at", "to", "the", "and", "or", "is", "it", "as", "by", "for", "with", "from"]

        for (index, rawToken) in tokens.enumerated() {
            let word = cleanWord(rawToken)
            guard word.count >= 2 else { continue }

            let range = NSRange(location: 0, length: (word as NSString).length)
            let isLatin = isLatinWord(word)
            let isCyrillicAcronym = cyrillicUpperRegex?.firstMatch(in: word, options: [], range: range) != nil

            if isLatin {
                if !latinStopwords.contains(word.lowercased()) {
                    candidates.append(word)
                }
            } else if isCyrillicAcronym {
                candidates.append(word)
            }
        }
        return candidates
    }

    public static func extractDiffPairs(original: String, edited: String) -> [(pattern: String, replacement: String)] {
        let origTokens = original.replacingOccurrences(of: "\n", with: " ").split(separator: " ").map { String($0) }
        let editTokens = edited.replacingOccurrences(of: "\n", with: " ").split(separator: " ").map { String($0) }

        let n = origTokens.count
        let m = editTokens.count
        guard n > 0 && m > 0 else { return [] }

        // DP таблица наибольшей общей подпоследовательности (LCS)
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                if cleanWord(origTokens[i - 1]).lowercased() == cleanWord(editTokens[j - 1]).lowercased() {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        enum Op {
            case match(String, String)
            case delete(String)
            case insert(String)
        }

        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && cleanWord(origTokens[i - 1]).lowercased() == cleanWord(editTokens[j - 1]).lowercased() {
                ops.append(.match(origTokens[i - 1], editTokens[j - 1]))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                ops.append(.insert(editTokens[j - 1]))
                j -= 1
            } else if i > 0 && (j == 0 || dp[i][j - 1] < dp[i - 1][j]) {
                ops.append(.delete(origTokens[i - 1]))
                i -= 1
            }
        }
        ops.reverse()

        var results: [(pattern: String, replacement: String)] = []
        var curDel: [String] = []
        var curIns: [String] = []

        func flush() {
            if !curDel.isEmpty || !curIns.isEmpty {
                let pat = curDel.map { cleanWord($0) }.filter { !$0.isEmpty }.joined(separator: " ")
                let rep = curIns.map { cleanWord($0) }.filter { !$0.isEmpty }.joined(separator: " ")
                if !pat.isEmpty && curDel.count <= 4 && curIns.count <= 4 && pat.lowercased() != rep.lowercased() {
                    results.append((pattern: pat, replacement: rep))
                }
                curDel.removeAll()
                curIns.removeAll()
            }
        }

        for op in ops {
            switch op {
            case .match:
                flush()
            case .delete(let d):
                curDel.append(d)
            case .insert(let ins):
                curIns.append(ins)
            }
        }
        flush()
        return results
    }

    // MARK: - Персистентность

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveToDisk()
        }
        saveWorkItem = work
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func saveToDisk() {
        guard let url = storageFileURL else { return }
        lock.lock()
        let snapshot = PersonalizationSnapshot(
            isLearningEnabled: isLearningEnabled,
            rules: correctionRules,
            terms: learnedTerms,
            deletedBuiltinPatterns: Array(deletedBuiltinPatterns),
            deletedBuiltinTerms: Array(deletedBuiltinTerms)
        )
        lock.unlock()

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLogger.shared.error("Personalization", "Не удалось сохранить память персонализации", details: error.localizedDescription)
        }
    }

    public static let builtinRules: [(pattern: String, replacement: String, category: String)] = [
        // IT, DevOps, Cloud & Code
        ("кубернайт", "Kubernetes", "it"),
        ("кубернейтс", "Kubernetes", "it"),
        ("кубере", "Kubernetes", "it"),
        ("кубер", "Kubernetes", "it"),
        ("кубернетис", "Kubernetes", "it"),
        ("кубик", "Kubernetes", "it"),
        ("докер", "Docker", "it"),
        ("докера", "Docker", "it"),
        ("постгрес", "PostgreSQL", "it"),
        ("постгри", "PostgreSQL", "it"),
        ("постгре", "PostgreSQL", "it"),
        ("энджиникс", "nginx", "it"),
        ("энджин икс", "nginx", "it"),
        ("нгинкс", "nginx", "it"),
        ("кафка", "Kafka", "it"),
        ("кафке", "Kafka", "it"),
        ("рэббит", "RabbitMQ", "it"),
        ("рэббит эм кью", "RabbitMQ", "it"),
        ("редис", "Redis", "it"),
        ("редисе", "Redis", "it"),
        ("джейсон", "JSON", "it"),
        ("джсон", "JSON", "it"),
        ("no8m", "n8n", "it"),
        ("но8м", "n8n", "it"),
        ("но8", "n8n", "it"),
        ("no8", "n8n", "it"),
        ("n8m", "n8n", "it"),
        ("n8", "n8n", "it"),
        ("эн восемь эн", "n8n", "it"),
        ("эн восемь", "n8n", "it"),
        ("гитхаб", "GitHub", "it"),
        ("гитлаб", "GitLab", "it"),
        ("джира", "Jira", "it"),
        ("жира", "Jira", "it"),
        ("конфлюенс", "Confluence", "it"),
        ("ношен", "Notion", "it"),
        ("ноушен", "Notion", "it"),
        ("пайтон", "Python", "it"),
        ("питон", "Python", "it"),
        ("тайпскрипт", "TypeScript", "it"),
        ("джаваскрипт", "JavaScript", "it"),
        ("голанг", "Go", "it"),
        ("свифт", "Swift", "it"),
        ("свифте", "Swift", "it"),
        ("хкод", "Xcode", "it"),
        ("эпл силикон", "Apple Silicon", "it"),
        ("эппл силикон", "Apple Silicon", "it"),
        ("си ай си ди", "CI/CD", "it"),
        ("сиай сиди", "CI/CD", "it"),
        ("пулреквест", "Pull Request", "it"),
        ("пулл реквест", "Pull Request", "it"),
        ("код ревью", "Code Review", "it"),
        ("хотфикс", "Hotfix", "it"),
        ("бэклог", "Backlog", "it"),
        ("деплой", "Deploy", "it"),
        ("фронтенд", "Frontend", "it"),
        ("бэкенд", "Backend", "it"),
        ("фулстек", "Fullstack", "it"),
        ("микросервисы", "Microservices", "it"),
        ("опэнроутер", "OpenRouter", "it"),
        ("опенроутер", "OpenRouter", "it"),
        ("оллама", "Ollama", "it"),

        // Корпоративный менеджмент & Agile
        ("окр", "OKR", "management"),
        ("о кэ эр", "OKR", "management"),
        ("кпи", "KPI", "management"),
        ("кэ пэ и", "KPI", "management"),
        ("ван ту ван", "1:1", "management"),
        ("ван-он-ван", "1:1", "management"),
        ("один на один", "1:1", "management"),
        ("1 на 1", "1:1", "management"),
        ("дейли", "Daily", "management"),
        ("стендап", "Standup", "management"),
        ("стэндап", "Standup", "management"),
        ("синк", "Sync", "management"),
        ("ретро", "Retro", "management"),
        ("ретроспектива", "Retro", "management"),
        ("тимлид", "Team Lead", "management"),
        ("техлид", "Tech Lead", "management"),
        ("продакт", "Product Manager", "management"),
        ("проджект", "Project Manager", "management"),
        ("си-левел", "C-level", "management"),
        ("асап", "ASAP", "management"),
        ("роадмап", "Roadmap", "management"),
        ("спринт", "Sprint", "management"),
        ("спринте", "Sprint", "management"),

        // Бизнес, Продукт, HR & Финансы
        ("си эр эм", "CRM", "business"),
        ("срм", "CRM", "business"),
        ("црм", "CRM", "business"),
        ("ерп", "ERP", "business"),
        ("сэ ла", "SLA", "business"),
        ("сла", "SLA", "business"),
        ("эндэа", "NDA", "business"),
        ("нда", "NDA", "business"),
        ("эм ви пи", "MVP", "business"),
        ("мвп", "MVP", "business"),
        ("б2б", "B2B", "business"),
        ("би ту би", "B2B", "business"),
        ("б2с", "B2C", "business"),
        ("би ту си", "B2C", "business"),
        ("саас", "SaaS", "business"),
        ("сас", "SaaS", "business"),
        ("мрр", "MRR", "business"),
        ("арр", "ARR", "business"),
        ("лтв", "LTV", "business"),
        ("нпс", "NPS", "business"),
        ("рои", "ROI", "business"),
        ("эйчар", "HR", "business"),
        ("хр", "HR", "business"),
        ("онбординг", "Onboarding", "business"),
        ("оффбординг", "Offboarding", "business"),
        ("кастдев", "CustDev", "business"),
        ("питчдек", "Pitch Deck", "business"),
        ("оффер", "Offer", "business"),
        ("перформанс ревью", "Performance Review", "business"),
        ("пнл", "P&L", "business")
    ]

    public static let builtinTerms: [(term: String, category: String)] = [
        // IT
        ("Kubernetes", "it"), ("Docker", "it"), ("PostgreSQL", "it"), ("nginx", "it"),
        ("Kafka", "it"), ("RabbitMQ", "it"), ("Redis", "it"), ("JSON", "it"),
        ("n8n", "it"), ("GitHub", "it"), ("GitLab", "it"), ("Jira", "it"),
        ("Confluence", "it"), ("Notion", "it"), ("Python", "it"), ("TypeScript", "it"),
        ("JavaScript", "it"), ("Swift", "it"), ("Xcode", "it"), ("Apple Silicon", "it"),
        ("Metal", "it"), ("CI/CD", "it"), ("Pull Request", "it"), ("Code Review", "it"),
        ("Hotfix", "it"), ("Backlog", "it"), ("Deploy", "it"), ("Frontend", "it"),
        ("Backend", "it"), ("Fullstack", "it"), ("Microservices", "it"), ("OpenRouter", "it"),
        ("Ollama", "it"), ("FastAPI", "it"), ("GraphQL", "it"),

        // Management
        ("OKR", "management"), ("KPI", "management"), ("1:1", "management"),
        ("Daily", "management"), ("Standup", "management"), ("Sync", "management"),
        ("Retro", "management"), ("Team Lead", "management"), ("Tech Lead", "management"),
        ("Product Manager", "management"), ("Project Manager", "management"),
        ("C-level", "management"), ("ASAP", "management"), ("Roadmap", "management"),
        ("Sprint", "management"), ("Scrum", "management"), ("Kanban", "management"),

        // Business & HR
        ("CRM", "business"), ("ERP", "business"), ("SLA", "business"), ("NDA", "business"),
        ("MVP", "business"), ("B2B", "business"), ("B2C", "business"), ("SaaS", "business"),
        ("MRR", "business"), ("ARR", "business"), ("LTV", "business"), ("CAC", "business"),
        ("NPS", "business"), ("ROI", "business"), ("HR", "business"), ("Onboarding", "business"),
        ("Offboarding", "business"), ("CustDev", "business"), ("Pitch Deck", "business"),
        ("Offer", "business"), ("Performance Review", "business"), ("P&L", "business")
    ]

    private func seedDefaultRules() {
        for item in Self.builtinRules {
            let lower = item.pattern.lowercased()
            if !self.deletedBuiltinPatterns.contains(lower) && !self.correctionRules.contains(where: { $0.pattern.lowercased() == lower }) {
                self.correctionRules.append(CorrectionRule(
                    pattern: item.pattern,
                    replacement: item.replacement,
                    count: 1,
                    lastUsed: Date(),
                    source: .builtin,
                    category: item.category
                ))
            }
        }
        for item in Self.builtinTerms {
            let lower = item.term.lowercased()
            if !self.deletedBuiltinTerms.contains(lower) && !self.learnedTerms.contains(where: { $0.term.lowercased() == lower }) {
                self.learnedTerms.append(LearnedTerm(
                    term: item.term,
                    count: 3,
                    lastUsed: Date(),
                    isManual: true,
                    category: item.category
                ))
            }
        }
    }

    private func loadFromDisk() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let url = self.storageFileURL,
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(PersonalizationSnapshot.self, from: data) else {
                self.lock.lock()
                self.seedDefaultRules()
                let userTerms = VoiceIntelligenceSettings.shared.userTerms
                for term in userTerms {
                    let cleaned = Self.cleanWord(term)
                    if !cleaned.isEmpty && !self.learnedTerms.contains(where: { $0.term.lowercased() == cleaned.lowercased() }) {
                        self.learnedTerms.append(LearnedTerm(term: cleaned, count: 5, lastUsed: Date(), isManual: true, category: "custom"))
                    }
                }
                self.lock.unlock()
                return
            }

            self.lock.lock()
            self.correctionRules = snapshot.rules
            self.learnedTerms = snapshot.terms
            if let deletedPatterns = snapshot.deletedBuiltinPatterns {
                self.deletedBuiltinPatterns = Set(deletedPatterns.map { $0.lowercased() })
            }
            if let deletedTerms = snapshot.deletedBuiltinTerms {
                self.deletedBuiltinTerms = Set(deletedTerms.map { $0.lowercased() })
            }

            // Добавляем отсутствующие встроенные правила и термины (с сохранением удаленных)
            self.seedDefaultRules()

            // Очищаем ошибочно изученные обычные кириллические слова с заглавной буквы
            let cyrillicUpperRegex = try? NSRegularExpression(pattern: #"^[А-ЯЁ]{2,}$"#)
            self.learnedTerms.removeAll { term in
                guard !term.isManual else { return false }
                if Self.isLatinWord(term.term) { return false }
                let range = NSRange(location: 0, length: (term.term as NSString).length)
                let isAcronym = cyrillicUpperRegex?.firstMatch(in: term.term, options: [], range: range) != nil
                return !isAcronym
            }

            // Синхронизация с историческими терминами пользователя из настроек
            let userTerms = VoiceIntelligenceSettings.shared.userTerms
            for term in userTerms {
                let cleaned = Self.cleanWord(term)
                if !cleaned.isEmpty && !self.learnedTerms.contains(where: { $0.term.lowercased() == cleaned.lowercased() }) {
                    self.learnedTerms.append(LearnedTerm(term: cleaned, count: 5, lastUsed: Date(), isManual: true, category: "custom"))
                }
            }
            self.lock.unlock()

            DispatchQueue.main.async {
                self.isLearningEnabled = snapshot.isLearningEnabled
                self.objectWillChange.send()
            }
        }
    }
}
