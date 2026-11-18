import Foundation

/// Блок конфига, который человек копирует в клиент нейронки: сервер `tranq` запускается
/// бинарником `tranq-mcp`, лежащим в `Contents/MacOS` рядом с исполняемым файлом самого приложения.
enum MCPConfigSnippet {
    /// Имя бинарника сервера рядом с исполняемым файлом приложения.
    static let binaryName = "tranq-mcp"
    /// Имя сервера в конфиге клиента.
    static let serverName = "tranq"

    /// JSON конфига. `binaryURL` — исполняемый файл приложения, путь к серверу берётся из его папки.
    /// Экранированием строки занимается `JSONSerialization`; ключи отсортированы, чтобы текст не менялся от вызова к вызову,
    /// а косые черты не экранируются, чтобы путь можно было прочитать и сверить глазами.
    static func text(binaryURL: URL) -> String {
        let command = binaryURL.deletingLastPathComponent().appendingPathComponent(binaryName).path
        let config: [String: Any] = ["mcpServers": [serverName: ["command": command]]]
        guard let data = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
