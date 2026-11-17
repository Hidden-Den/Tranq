import Foundation

/// Где идёт диктовка: приложение, сайт активной вкладки и просьба о промпте.
/// Снимается в начале записи и не меняется до её конца.
struct DictationContext: Equatable {
    let bundleId: String?
    let host: String?
    let promptRequested: Bool
}

struct ResolvedLevel: Equatable {
    let level: CleanupLevel
    /// Подпись для экрана записи.
    let label: String
    /// Имя сработавшего правила; пусто, если правила не было.
    let ruleName: String?
}

enum CleanupLevelResolver {
    /// Порядок: промпт по Shift, прямой ввод, правило сайта, правило приложения, чистая мысль.
    static func resolve(
        _ context: DictationContext,
        rules: [DictationRule],
        mode: VoiceInputMode,
        promptModeEnabled: Bool
    ) -> ResolvedLevel {
        if context.promptRequested && promptModeEnabled {
            return ResolvedLevel(level: .prompt, label: "Промпт", ruleName: nil)
        }
        if mode == .direct {
            return ResolvedLevel(level: .verbatim, label: "Дословно", ruleName: nil)
        }
        if let rule = siteRule(for: context.host, in: rules) ?? appRule(for: context.bundleId, in: rules) {
            return ResolvedLevel(level: .rewrite(tone: rule.tone.instruction), label: rule.displayName, ruleName: rule.displayName)
        }
        return ResolvedLevel(level: .clean, label: "Чисто", ruleName: nil)
    }

    private static func siteRule(for host: String?, in rules: [DictationRule]) -> DictationRule? {
        guard let host else { return nil }
        var best: (rule: DictationRule, length: Int)?
        for rule in rules where rule.isEnabled {
            guard case .site(let domain) = rule.target, DomainNormalizer.matches(host: host, ruleDomain: domain) else { continue }
            if best == nil || domain.count > best!.length {
                best = (rule, domain.count)
            }
        }
        return best?.rule
    }

    private static func appRule(for bundleId: String?, in rules: [DictationRule]) -> DictationRule? {
        guard let bundleId else { return nil }
        return rules.first { rule in
            guard rule.isEnabled, case .app(let id) = rule.target else { return false }
            return id == bundleId
        }
    }
}

enum DomainNormalizer {
    /// Адрес или домен приводится к виду «mail.company.ru»: без схемы, порта, пути, `www.` и точки в конце.
    static func host(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var host = URLComponents(string: withScheme)?.host?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// Домен правила совпадает с самим адресом и с его поддоменами.
    static func matches(host: String, ruleDomain: String) -> Bool {
        let host = host.lowercased()
        let domain = ruleDomain.lowercased()
        guard !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }
}
