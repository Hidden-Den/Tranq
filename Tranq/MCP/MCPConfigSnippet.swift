import Foundation

/// Блоки, которые человек копирует в клиент нейронки: сервер `tranq` запускается бинарником `tranq-mcp`,
/// лежащим в `Contents/MacOS` рядом с исполняемым файлом самого приложения.
/// Клиентов с JSON-конфигом `mcpServers` обслуживает `text`, Codex хранит серверы в TOML и получает
/// команду `codex mcp add`: так человек не правит файл руками.
enum MCPConfigSnippet {
    /// Имя бинарника сервера рядом с исполняемым файлом приложения.
    static let binaryName = "tranq-mcp"
    /// Имя сервера в конфиге клиента.
    static let serverName = "tranq"

    /// Путь к серверу: `binaryURL` — исполняемый файл приложения, сервер лежит в его папке.
    private static func serverPath(binaryURL: URL) -> String {
        binaryURL.deletingLastPathComponent().appendingPathComponent(binaryName).path
    }

    /// JSON конфига. Экранированием строки занимается `JSONSerialization`; ключи отсортированы, чтобы текст
    /// не менялся от вызова к вызову, а косые черты не экранируются, чтобы путь можно было прочитать и сверить глазами.
    static func text(binaryURL: URL) -> String {
        let config: [String: Any] = ["mcpServers": [serverName: ["command": serverPath(binaryURL: binaryURL)]]]
        guard let data = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Команда для терминала, которая записывает сервер в конфиг Codex.
    static func codexCommand(binaryURL: URL) -> String {
        "codex mcp add \(serverName) -- \(shellWord(serverPath(binaryURL: binaryURL)))"
    }

    /// Символы, которые оболочка оставляет как есть. Всё остальное, включая не латинские буквы, идёт в кавычках.
    private static let plainShellCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-".unicodeScalars
    )

    /// Одно слово для `sh`: обычный путь без изменений, остальное в одинарных кавычках, внутри которых
    /// оболочка ничего не раскрывает. Одинарная кавычка закрывает строку, ставится с обратной косой чертой
    /// и открывает её заново.
    static func shellWord(_ text: String) -> String {
        if !text.isEmpty, text.unicodeScalars.allSatisfy(plainShellCharacters.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
