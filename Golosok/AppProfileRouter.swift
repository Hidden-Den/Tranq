import Foundation

public enum AppCategory: String, CaseIterable, Equatable {
    case messaging
    case codeAndTerminal
    case notesAndDocs
    case email
    case general

    public var guidancePrompt: String {
        switch self {
        case .messaging:
            return "Контекст целевого приложения: мессенджер. Текст должен быть лаконичным, живым, без избыточных зачинов и канцеляризмов."
        case .codeAndTerminal:
            return "Контекст целевого приложения: редактор кода или терминал. Строго сохраняй регистр идентификаторов, camelCase, snake_case и английские термины без русификации."
        case .notesAndDocs:
            return "Контекст целевого приложения: база знаний или заметки. Сохраняй структуру, используй списки и форматирование Markdown там, где это уместно."
        case .email:
            return "Контекст целевого приложения: электронная почта. Соблюдай вежливый деловой тон и структурируй текст по абзацам."
        case .general:
            return ""
        }
    }
}

public struct AppProfileRouter {
    public static func detectCategory(bundleIdentifier: String?) -> AppCategory {
        guard let bundleId = bundleIdentifier?.lowercased(), !bundleId.isEmpty else {
            return .general
        }

        // Мессенджеры
        let messagingPrefixes = [
            "telegram", "slack", "mobilesms", "whatsapp", "discord", "skype", "element"
        ]
        if messagingPrefixes.contains(where: { bundleId.contains($0) }) {
            return .messaging
        }

        // Код и терминал
        let codePrefixes = [
            "vscode", "xcode", "terminal", "iterm", "cursor", "jetbrains", "sublime", "alacritty", "kitty", "warp", "com.todesktop.230313mzl4w4u92"
        ]
        if codePrefixes.contains(where: { bundleId.contains($0) }) {
            return .codeAndTerminal
        }

        // Заметки и базы знаний
        let notesPrefixes = [
            "obsidian", "notion", "notes", "craft", "bear", "logseq", "anytype"
        ]
        if notesPrefixes.contains(where: { bundleId.contains($0) }) {
            return .notesAndDocs
        }

        // Почта
        let emailPrefixes = [
            "mail", "outlook", "thunderbird", "spark", "mimestream"
        ]
        if emailPrefixes.contains(where: { bundleId.contains($0) }) {
            return .email
        }

        return .general
    }
}
