import Foundation
import AppKit

/// Черновик правила в листе добавления.
struct RuleDraft: Equatable {
    enum Kind { case app, site }
    var kind: Kind
    var bundleId: String?
    var appName: String?
    var domainInput: String
    var tone: RuleTone
    /// Текст поля «Как писать текст»; используется, когда выбран свой тон.
    var customText: String
}

enum RuleEditorError: Error, Equatable {
    case emptyTarget
    case invalidDomain
    case emptyCustomTone
    case duplicate
}

enum RuleEditorLogic {
    /// Проверяет черновик и собирает правило. Порядок проверок: цель, тон, повтор.
    static func makeRule(
        from draft: RuleDraft,
        existing: [DictationRule],
        id: UUID = UUID()
    ) -> Result<DictationRule, RuleEditorError> {
        let target: RuleTarget
        let displayName: String
        switch draft.kind {
        case .site:
            guard let host = DomainNormalizer.host(from: draft.domainInput) else { return .failure(.invalidDomain) }
            target = .site(domain: host)
            displayName = host
        case .app:
            guard let bundleId = draft.bundleId, !bundleId.isEmpty else { return .failure(.emptyTarget) }
            target = .app(bundleId: bundleId)
            displayName = draft.appName?.isEmpty == false ? draft.appName! : bundleId
        }

        let tone: RuleTone
        if case .custom(let value) = draft.tone {
            let inline = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = inline.isEmpty ? draft.customText.trimmingCharacters(in: .whitespacesAndNewlines) : inline
            guard !text.isEmpty else { return .failure(.emptyCustomTone) }
            tone = .custom(text)
        } else {
            tone = draft.tone
        }

        guard !existing.contains(where: { $0.target == target }) else { return .failure(.duplicate) }
        return .success(DictationRule(id: id, target: target, displayName: displayName, tone: tone, isEnabled: true))
    }

    /// Запущенные приложения с окнами, без самого Голоска, по имени.
    static func runningApps() -> [(bundleId: String, name: String)] {
        var seen = Set<String>()
        var result: [(bundleId: String, name: String)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleId = app.bundleIdentifier, bundleId != Bundle.main.bundleIdentifier,
                  seen.insert(bundleId).inserted else { continue }
            result.append((bundleId, app.localizedName ?? bundleId))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Что показать под переключателем режима промпта.
enum PromptModeHint: Equatable {
    /// Сочетание для одной диктовки, например «⇧ + Fn».
    case available(String)
    /// Shift уже занят самой клавишей.
    case unavailableShift
    case noHotKey

    static func make(for trigger: HotKeyTrigger) -> PromptModeHint {
        if trigger == .none { return .noHotKey }
        guard let variant = trigger.promptVariant else { return .unavailableShift }
        if case .singleModifier = variant { return .available("⇧ + " + variant.displayName) }
        return .available(variant.displayName)
    }
}
