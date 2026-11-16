import Foundation

/// Однократный перенос данных старой персонализации в словарь.
///
/// Файл не зависит от `PersonalizationEngine`: нужные структуры и снимок встроенных списков скопированы сюда.
/// Запускается из `DictionaryStore.shared` на главном потоке: если `shared` создан с другого потока,
/// перенос ставится в очередь главного без ожидания, чтобы исключить взаимную блокировку.
/// Повторный запуск безопасен: `addEntry` объединяет записи по написанию, а варианты без повторов.
enum DictionaryMigration {
    static let legacyFileName = "personalization.json"
    static let migratedFileName = "personalization.v1.json"
    static let userTermsKey = "voice.userTerms"

    private struct LegacyRule: Codable {
        var pattern: String
        var replacement: String
        var source: String
    }

    private struct LegacyTerm: Codable {
        var term: String
        var isManual: Bool
    }

    private struct LegacySnapshot: Codable {
        var rules: [LegacyRule]
        var terms: [LegacyTerm]
    }

    static func runIfNeeded(store: DictionaryStore, directory: URL, defaults: UserDefaults) {
        let fm = FileManager.default
        let legacyURL = directory.appendingPathComponent(legacyFileName)
        let migratedURL = directory.appendingPathComponent(migratedFileName)
        guard fm.fileExists(atPath: legacyURL.path), !fm.fileExists(atPath: migratedURL.path) else { return }

        let snapshot: LegacySnapshot
        do {
            snapshot = try JSONDecoder().decode(LegacySnapshot.self, from: Data(contentsOf: legacyURL))
        } catch {
            AppLogger.shared.warn("Dictionary", "Старая персонализация не прочитана", details: error.localizedDescription)
            return
        }

        let builtinPairs = Set(builtinRules.map { pairKey($0.0, $0.1) })
        let builtinTermKeys = Set(builtinTerms.map { $0.lowercased() })

        // Порядок групп и вариантов сохраняется по порядку правил.
        struct Group {
            var spelling: String
            var variants: [String] = []
            var manual = false
        }
        var groups: [String: Group] = [:]
        var order: [String] = []
        var dropped = 0
        var droppedEmpty = 0

        for rule in snapshot.rules {
            let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !replacement.isEmpty else {
                droppedEmpty += 1
                AppLogger.shared.info("Dictionary", "Правило без замены отброшено", details: pattern)
                continue
            }
            guard !pattern.isEmpty else { dropped += 1; continue }

            var manual = false
            switch rule.source {
            case "manual":
                manual = true
            case "edit":
                guard DictionaryLearning.isLearnablePair(pattern: pattern, replacement: replacement, language: .ru) else {
                    dropped += 1
                    continue
                }
            case "builtin":
                guard !builtinPairs.contains(pairKey(pattern, replacement)) else { dropped += 1; continue }
                manual = true
            default:
                dropped += 1
                continue
            }

            let key = replacement.lowercased()
            var group = groups[key] ?? Group(spelling: replacement)
            if groups[key] == nil { order.append(key) }
            if !group.variants.contains(where: { $0.lowercased() == pattern.lowercased() }) {
                group.variants.append(pattern)
            }
            group.manual = group.manual || manual
            groups[key] = group
        }

        var terms: [String] = []
        var seenTerms = Set<String>()
        let userTerms = defaults.stringArray(forKey: userTermsKey) ?? []
        let manualTerms = snapshot.terms.filter { $0.isManual && !builtinTermKeys.contains($0.term.lowercased()) }.map(\.term)
        for raw in manualTerms + userTerms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty, seenTerms.insert(term.lowercased()).inserted { terms.append(term) }
        }

        for key in order {
            guard let group = groups[key] else { continue }
            store.addEntry(
                spelling: group.spelling, variants: [.ru: group.variants],
                source: group.manual ? .manual : .learned
            )
        }
        for term in terms {
            store.addEntry(spelling: term, variants: [:], source: .manual)
        }

        do {
            try fm.moveItem(at: legacyURL, to: migratedURL)
        } catch {
            AppLogger.shared.warn("Dictionary", "Старая персонализация не переименована", details: error.localizedDescription)
            store.flush()
            return
        }
        defaults.removeObject(forKey: userTermsKey)
        store.flush()
        AppLogger.shared.info(
            "Dictionary", "Перенос персонализации завершён",
            details: "записей \(order.count), терминов \(terms.count), отброшено \(dropped), без замены \(droppedEmpty)"
        )
    }

    private static func pairKey(_ pattern: String, _ replacement: String) -> String {
        "\(pattern.lowercased())|\(replacement.lowercased())"
    }

    // MARK: - Снимок встроенных списков старой персонализации

    private static let builtinRules: [(String, String)] = [
        ("кубернайт", "Kubernetes"),
        ("кубернейтс", "Kubernetes"),
        ("кубере", "Kubernetes"),
        ("кубер", "Kubernetes"),
        ("кубернетис", "Kubernetes"),
        ("кубик", "Kubernetes"),
        ("докер", "Docker"),
        ("докера", "Docker"),
        ("постгрес", "PostgreSQL"),
        ("постгри", "PostgreSQL"),
        ("постгре", "PostgreSQL"),
        ("энджиникс", "nginx"),
        ("энджин икс", "nginx"),
        ("нгинкс", "nginx"),
        ("кафка", "Kafka"),
        ("кафке", "Kafka"),
        ("рэббит", "RabbitMQ"),
        ("рэббит эм кью", "RabbitMQ"),
        ("редис", "Redis"),
        ("редисе", "Redis"),
        ("джейсон", "JSON"),
        ("джсон", "JSON"),
        ("no8m", "n8n"),
        ("но8м", "n8n"),
        ("но8", "n8n"),
        ("no8", "n8n"),
        ("n8m", "n8n"),
        ("n8", "n8n"),
        ("эн восемь эн", "n8n"),
        ("эн восемь", "n8n"),
        ("гитхаб", "GitHub"),
        ("гитлаб", "GitLab"),
        ("джира", "Jira"),
        ("жира", "Jira"),
        ("конфлюенс", "Confluence"),
        ("ношен", "Notion"),
        ("ноушен", "Notion"),
        ("пайтон", "Python"),
        ("питон", "Python"),
        ("тайпскрипт", "TypeScript"),
        ("джаваскрипт", "JavaScript"),
        ("голанг", "Go"),
        ("свифт", "Swift"),
        ("свифте", "Swift"),
        ("хкод", "Xcode"),
        ("эпл силикон", "Apple Silicon"),
        ("эппл силикон", "Apple Silicon"),
        ("си ай си ди", "CI/CD"),
        ("сиай сиди", "CI/CD"),
        ("пулреквест", "Pull Request"),
        ("пулл реквест", "Pull Request"),
        ("код ревью", "Code Review"),
        ("хотфикс", "Hotfix"),
        ("бэклог", "Backlog"),
        ("деплой", "Deploy"),
        ("фронтенд", "Frontend"),
        ("бэкенд", "Backend"),
        ("фулстек", "Fullstack"),
        ("микросервисы", "Microservices"),
        ("опэнроутер", "OpenRouter"),
        ("опенроутер", "OpenRouter"),
        ("оллама", "Ollama"),
        ("окр", "OKR"),
        ("о кэ эр", "OKR"),
        ("кпи", "KPI"),
        ("кэ пэ и", "KPI"),
        ("ван ту ван", "1:1"),
        ("ван-он-ван", "1:1"),
        ("один на один", "1:1"),
        ("1 на 1", "1:1"),
        ("дейли", "Daily"),
        ("стендап", "Standup"),
        ("стэндап", "Standup"),
        ("синк", "Sync"),
        ("ретро", "Retro"),
        ("ретроспектива", "Retro"),
        ("тимлид", "Team Lead"),
        ("техлид", "Tech Lead"),
        ("продакт", "Product Manager"),
        ("проджект", "Project Manager"),
        ("си-левел", "C-level"),
        ("асап", "ASAP"),
        ("роадмап", "Roadmap"),
        ("спринт", "Sprint"),
        ("спринте", "Sprint"),
        ("си эр эм", "CRM"),
        ("срм", "CRM"),
        ("црм", "CRM"),
        ("ерп", "ERP"),
        ("сэ ла", "SLA"),
        ("сла", "SLA"),
        ("эндэа", "NDA"),
        ("нда", "NDA"),
        ("эм ви пи", "MVP"),
        ("мвп", "MVP"),
        ("б2б", "B2B"),
        ("би ту би", "B2B"),
        ("б2с", "B2C"),
        ("би ту си", "B2C"),
        ("саас", "SaaS"),
        ("сас", "SaaS"),
        ("мрр", "MRR"),
        ("арр", "ARR"),
        ("лтв", "LTV"),
        ("нпс", "NPS"),
        ("рои", "ROI"),
        ("эйчар", "HR"),
        ("хр", "HR"),
        ("онбординг", "Onboarding"),
        ("оффбординг", "Offboarding"),
        ("кастдев", "CustDev"),
        ("питчдек", "Pitch Deck"),
        ("оффер", "Offer"),
        ("перформанс ревью", "Performance Review"),
        ("пнл", "P&L")
    ]

    private static let builtinTerms: [String] = [
        "Kubernetes",
        "Docker",
        "PostgreSQL",
        "nginx",
        "Kafka",
        "RabbitMQ",
        "Redis",
        "JSON",
        "n8n",
        "GitHub",
        "GitLab",
        "Jira",
        "Confluence",
        "Notion",
        "Python",
        "TypeScript",
        "JavaScript",
        "Swift",
        "Xcode",
        "Apple Silicon",
        "Metal",
        "CI/CD",
        "Pull Request",
        "Code Review",
        "Hotfix",
        "Backlog",
        "Deploy",
        "Frontend",
        "Backend",
        "Fullstack",
        "Microservices",
        "OpenRouter",
        "Ollama",
        "FastAPI",
        "GraphQL",
        "OKR",
        "KPI",
        "1:1",
        "Daily",
        "Standup",
        "Sync",
        "Retro",
        "Team Lead",
        "Tech Lead",
        "Product Manager",
        "Project Manager",
        "C-level",
        "ASAP",
        "Roadmap",
        "Sprint",
        "Scrum",
        "Kanban",
        "CRM",
        "ERP",
        "SLA",
        "NDA",
        "MVP",
        "B2B",
        "B2C",
        "SaaS",
        "MRR",
        "ARR",
        "LTV",
        "CAC",
        "NPS",
        "ROI",
        "HR",
        "Onboarding",
        "Offboarding",
        "CustDev",
        "Pitch Deck",
        "Offer",
        "Performance Review",
        "P&L",
    ]
}
