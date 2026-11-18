import Testing
import Foundation
@testable import Tranq

/// Блок конфига для клиента нейронки: путь к `tranq-mcp` рядом с исполняемым файлом приложения.
struct MCPConfigSnippetTests {
    /// Команда и ключ сервера из текста конфига. Разбор общий для нескольких проверок.
    private func parsed(_ text: String) -> (server: String, command: String)? {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return nil }
        guard servers.count == 1 else {
            Issue.record("В mcpServers ожидался один сервер, найдено \(servers.count): \(servers.keys.sorted())")
            return nil
        }
        guard let name = servers.keys.first,
              let entry = servers[name] as? [String: Any],
              let command = entry["command"] as? String else { return nil }
        return (name, command)
    }

    @Test func конфигУказываетНаБинарникРядомСПриложением() {
        let exe = URL(fileURLWithPath: "/Users/kto/Applications/Tranq.app/Contents/MacOS/Tranq")
        let text = MCPConfigSnippet.text(binaryURL: exe)
        #expect(text.contains("/Users/kto/Applications/Tranq.app/Contents/MacOS/tranq-mcp"))
        #expect(text.contains("\"tranq\""))
    }

    @Test func конфигЭтоКорректныйJSONСОдномСервером() {
        let exe = URL(fileURLWithPath: "/Applications/Tranq.app/Contents/MacOS/Tranq")
        let result = parsed(MCPConfigSnippet.text(binaryURL: exe))
        #expect(result?.server == "tranq")
        #expect(result?.command == "/Applications/Tranq.app/Contents/MacOS/tranq-mcp")
    }

    @Test func путьСПробеломИКавычкойЭкранируетсяИВозвращаетсяБезПотерь() {
        // Пробел в имени пользователя и кавычка в имени папки не ломают JSON.
        let exe = URL(fileURLWithPath: "/Users/Иван Петров/Мои \"приложения\"/Tranq.app/Contents/MacOS/Tranq")
        let text = MCPConfigSnippet.text(binaryURL: exe)
        #expect(parsed(text)?.command == "/Users/Иван Петров/Мои \"приложения\"/Tranq.app/Contents/MacOS/tranq-mcp")
    }

    @Test func косыеЧертыВПутиНеЭкранируются() {
        // Путь копируют руками, обратные косые черты в нём только мешают.
        let exe = URL(fileURLWithPath: "/Applications/Tranq.app/Contents/MacOS/Tranq")
        #expect(!MCPConfigSnippet.text(binaryURL: exe).contains("\\/"))
    }

    @Test func текстСтабиленИРазбитНаСтроки() {
        let exe = URL(fileURLWithPath: "/Applications/Tranq.app/Contents/MacOS/Tranq")
        let first = MCPConfigSnippet.text(binaryURL: exe)
        #expect(first == MCPConfigSnippet.text(binaryURL: exe))
        #expect(first.contains("\n"))
    }

    // MARK: Команда для Codex

    @Test func командаДляCodexДобавляетСерверСОбычнымПутёмБезКавычек() {
        let exe = URL(fileURLWithPath: "/Applications/Tranq.app/Contents/MacOS/Tranq")
        #expect(MCPConfigSnippet.codexCommand(binaryURL: exe)
                == "codex mcp add tranq -- /Applications/Tranq.app/Contents/MacOS/tranq-mcp")
    }

    @Test func путьСПробеломВКомандеБерётсяВОдинарныеКавычки() {
        let exe = URL(fileURLWithPath: "/Users/Иван Петров/Tranq.app/Contents/MacOS/Tranq")
        #expect(MCPConfigSnippet.codexCommand(binaryURL: exe)
                == "codex mcp add tranq -- '/Users/Иван Петров/Tranq.app/Contents/MacOS/tranq-mcp'")
    }

    @Test func одинарнаяКавычкаВПутиЗакрываетИОткрываетКавычкиЗаново() {
        #expect(MCPConfigSnippet.shellWord("/Users/O'Brien/tranq-mcp") == #"'/Users/O'\''Brien/tranq-mcp'"#)
    }

    @Test func спецсимволыОболочкиОстаютсяВнутриОдинарныхКавычек() {
        let path = #"/tmp/a$b`c"d\e;f&g|h(i)*j"#
        #expect(MCPConfigSnippet.shellWord(path) == "'" + path + "'")
    }

    @Test func пустаяСтрокаСтановитсяПустымиКавычками() {
        #expect(MCPConfigSnippet.shellWord("") == "''")
    }

    @Test func словоПроходитЧерезОболочкуБезПотерь() throws {
        // Главная гарантия: что бы ни лежало в пути, оболочка получает его одним словом и без изменений.
        let paths = [
            "/Applications/Tranq.app/Contents/MacOS/tranq-mcp",
            "/Users/Иван Петров/Мои \"приложения\"/tranq-mcp",
            "/Users/O'Brien/tranq-mcp",
            #"/tmp/a$b`c"d\e;f&g|h(i)*j#k~l!m"#,
            "/tmp/two  spaces/and\ttab/tranq-mcp",
        ]
        for path in paths {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s " + MCPConfigSnippet.shellWord(path)]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(String(decoding: data, as: UTF8.self) == path)
        }
    }
}
