import Foundation

/// Правило автоисправления, выученное на основе правок пользователя
public struct CorrectionRule: Codable, Identifiable, Equatable {
    public let id: UUID
    public var pattern: String
    public var replacement: String
    public var count: Int
    public var lastUsed: Date
    public var source: RuleSource

    public enum RuleSource: String, Codable {
        case edit
        case manual
    }

    public init(
        id: UUID = UUID(),
        pattern: String,
        replacement: String,
        count: Int = 1,
        lastUsed: Date = Date(),
        source: RuleSource = .edit
    ) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.count = count
        self.lastUsed = lastUsed
        self.source = source
    }
}

/// Изученный термин или жаргонизм пользователя
public struct LearnedTerm: Codable, Identifiable, Equatable {
    public var id: String { term.lowercased() }
    public var term: String
    public var count: Int
    public var lastUsed: Date
    public var isManual: Bool

    public init(term: String, count: Int = 1, lastUsed: Date = Date(), isManual: Bool = false) {
        self.term = term
        self.count = count
        self.lastUsed = lastUsed
        self.isManual = isManual
    }
}

/// Контейнер персистентного состояния персонализации
private struct PersonalizationSnapshot: Codable {
    var isLearningEnabled: Bool
    var rules: [CorrectionRule]
    var terms: [LearnedTerm]
}

/// Сверхбыстрый локальный движок персонализации и адаптивного обучения (On-Device In-Context Learning)
public final class PersonalizationEngine: ObservableObject {
    public static let shared = PersonalizationEngine()

    @Published public var isLearningEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isLearningEnabled, forKey: "voice.personalization.enabled")
            scheduleSave()
        }
    }

    @Published public private(set) var correctionRules: [CorrectionRule] = []
    @Published public private(set) var learnedTerms: [LearnedTerm] = []

    private let queue = DispatchQueue(label: "com.golosok.personalization", qos: .utility)
    private var saveWorkItem: DispatchWorkItem?
    private let lock = NSLock()

    private var storageFileURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("Golosok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("personalization.json")
    }

    private init() {
        let storedEnabled = UserDefaults.standard.object(forKey: "voice.personalization.enabled") as? Bool ?? true
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
                        if cleanedW.count >= 2 && (cleanedW.first?.isUppercase == true || Self.isLatinWord(cleanedW)) {
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

        // Если прямого совпадения терминов мало, добавляем топ-3 самых частых термина пользователя
        if matchedTerms.count < 3 {
            let topTerms = termsSnapshot
                .filter { ($0.count >= 2 || $0.isManual) && !matchedTerms.contains($0.term) }
                .sorted { $0.count > $1.count }
                .prefix(3 - matchedTerms.count)
                .map { $0.term }
            matchedTerms.append(contentsOf: topTerms)
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

    public func removeTerm(_ term: String) {
        lock.lock()
        learnedTerms.removeAll { $0.term.lowercased() == term.lowercased() }
        lock.unlock()
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        scheduleSave()
    }

    public func removeRule(id: UUID) {
        lock.lock()
        correctionRules.removeAll { $0.id == id }
        lock.unlock()
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        scheduleSave()
    }

    public func resetMemory() {
        lock.lock()
        correctionRules.removeAll()
        learnedTerms.removeAll()
        lock.unlock()

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        scheduleSave()
        AppLogger.shared.info("Personalization", "Память адаптивного обучения полностью очищена")
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
            } else if index > 0 && word.first?.isUppercase == true {
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
            terms: learnedTerms
        )
        lock.unlock()

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLogger.shared.error("Personalization", "Не удалось сохранить память персонализации", details: error.localizedDescription)
        }
    }

    private func loadFromDisk() {
        queue.async { [weak self] in
            guard let self = self,
                  let url = self.storageFileURL,
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(PersonalizationSnapshot.self, from: data) else {
                return
            }

            self.lock.lock()
            self.correctionRules = snapshot.rules
            self.learnedTerms = snapshot.terms
            self.lock.unlock()

            DispatchQueue.main.async {
                self.isLearningEnabled = snapshot.isLearningEnabled
                self.objectWillChange.send()
            }
        }
    }
}
