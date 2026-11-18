import Testing
import Foundation
@testable import Tranq

/// Сокет двери: настоящий Unix-сокет во временной папке, настоящая дверь над временными хранилищами.
/// Тесты не трогают сокет приложения: у каждого свой короткий путь и свой экземпляр сервера.
/// Дверь уходит на главный поток, поэтому тесты не держат главный поток, пока ждут ответа.
final class MCPSocketServerTests {
    private let root: URL
    private let socketPath: String
    private let suiteName: String
    private let accessSuiteName: String

    init() {
        let tag = String(UUID().uuidString.prefix(8))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcps-\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        socketPath = root.appendingPathComponent("m.sock").path
        suiteName = "mcp-socket-dict-\(tag)"
        accessSuiteName = "mcp-socket-access-\(tag)"
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        UserDefaults(suiteName: accessSuiteName)?.removePersistentDomain(forName: accessSuiteName)
    }

    // MARK: - Сборка

    private func makeDoor() async -> MCPDoor {
        let root = root, suiteName = suiteName, accessSuiteName = accessSuiteName
        return await MainActor.run {
            let pack = DictionaryPack(
                id: "it",
                title: [.ru: "Программирование", .en: "Programming"],
                version: 1,
                entries: [PackEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]])]
            )
            let dictDir = root.appendingPathComponent("dict", isDirectory: true)
            try? FileManager.default.createDirectory(at: dictDir, withIntermediateDirectories: true)
            let dictionary = DictionaryStore(
                directory: dictDir, defaults: UserDefaults(suiteName: suiteName)!, packsBundle: .main,
                checker: SetCommonWordChecker([:]), packs: [pack]
            )
            let history = HistoryStore(directory: root.appendingPathComponent("history", isDirectory: true), saveDelay: 10)
            let access = MCPAccess(defaults: UserDefaults(suiteName: accessSuiteName)!)
            access.enabled = true
            return MCPDoor(dictionary: dictionary, history: history, access: access, language: .ru)
        }
    }

    private func startServer() async -> MCPSocketServer {
        let server = MCPSocketServer(path: socketPath)
        server.start(door: await makeDoor())
        return server
    }

    private func object(_ line: String?) -> [String: Any]? {
        guard let line else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    // MARK: - Тесты из задачи

    @Test(.timeLimit(.minutes(1)))
    func сокетСоздаётсяСПравами0600() async throws {
        let server = await startServer()
        defer { server.stop() }

        var info = stat()
        #expect(lstat(socketPath, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test(.timeLimit(.minutes(1)))
    func двеОдновременныеСессииПолучаютСвоиОтветы() async throws {
        let server = await startServer()
        defer { server.stop() }

        let first = try TestClient(path: socketPath)
        let second = try TestClient(path: socketPath)
        // Первый начал строку и замолчал: второй не должен ждать его конца
        try first.send(#"{"cmd":"pa"#)
        try second.send(#"{"cmd":"нет такой"}"# + "\n")
        let secondAnswer = object(second.readLine())
        #expect(secondAnswer?["ok"] as? Bool == false)

        try first.send(#"cks"}"# + "\n")
        let firstAnswer = object(first.readLine())
        #expect(firstAnswer?["ok"] as? Bool == true)
        let packs = firstAnswer?["data"] as? [[String: Any]]
        #expect(packs?.first?["id"] as? String == "it")

        // Ответы ушли только своим клиентам: лишних строк ни у кого нет
        #expect(first.readLine(timeout: 0.3) == nil)
        #expect(second.readLine(timeout: 0.3) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func файлОтПрошлогоЗапускаНеМешаетСтарту() async throws {
        FileManager.default.createFile(atPath: socketPath, contents: Data("остаток".utf8))
        let server = await startServer()
        defer { server.stop() }

        let client = try TestClient(path: socketPath)
        try client.send(#"{"cmd":"packs"}"# + "\n")
        #expect(object(client.readLine())?["ok"] as? Bool == true)
    }

    // MARK: - Поведение транспорта

    @Test(.timeLimit(.minutes(1)))
    func запросИОтветЧерезНастоящийСокет() async throws {
        let server = await startServer()
        defer { server.stop() }

        let client = try TestClient(path: socketPath)
        try client.send(#"{"cmd":"packs"}"# + "\r\n")
        let answer = object(client.readLine())
        #expect(answer?["ok"] as? Bool == true)
        #expect(answer?["language"] as? String == "ru")
        let packs = answer?["data"] as? [[String: Any]]
        #expect(packs?.count == 1)
        #expect(packs?.first?["title"] as? String == "Программирование")

        // Пустая строка пропускается без ответа, соединение живёт дальше
        try client.send("\n" + #"{"cmd":"packs"}"# + "\n")
        #expect(object(client.readLine())?["ok"] as? Bool == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func слишкомДлиннаяСтрокаПолучаетОтказИСоединениеЗакрывается() async throws {
        let server = await startServer()
        defer { server.stop() }

        let client = try TestClient(path: socketPath)
        let huge = String(repeating: "x", count: MCPSocketServer.maxLineBytes + 100) + "\n"
        client.sendIgnoringErrors(huge)
        let answer = object(client.readLine())
        #expect(answer?["ok"] as? Bool == false)
        #expect((answer?["error"] as? String)?.isEmpty == false)
        #expect(answer?["language"] as? String == "ru")
        #expect(client.isClosedByPeer())
    }

    @Test(.timeLimit(.minutes(1)))
    func клиентУшедшийПосредиСтрокиНеЛомаетСледующего() async throws {
        let server = await startServer()
        defer { server.stop() }

        // Ушёл посреди строки
        let broken = try TestClient(path: socketPath)
        try broken.send(#"{"cmd":"pac"#)
        broken.close()
        // Ушёл, не дождавшись ответа: сервер пишет в закрытый сокет и не падает от SIGPIPE
        let impatient = try TestClient(path: socketPath)
        try impatient.send(#"{"cmd":"packs"}"# + "\n")
        impatient.close()
        try await Task.sleep(nanoseconds: 300_000_000)

        let next = try TestClient(path: socketPath)
        try next.send(#"{"cmd":"packs"}"# + "\n")
        #expect(object(next.readLine())?["ok"] as? Bool == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func остановкаСГлавногоПотокаПриЖивомКлиентеНеЗависает() async throws {
        let server = await startServer()
        let client = try TestClient(path: socketPath)
        try client.send(#"{"cmd":"packs"}"# + "\n")
        #expect(object(client.readLine())?["ok"] as? Bool == true)

        await MainActor.run { server.stop() }

        #expect(client.isClosedByPeer())
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        #expect(!server.isRunning)
    }

    @Test(.timeLimit(.minutes(1)))
    func соединениеСверхПределаПолучаетОтказАЖивыеРаботают() async throws {
        let server = await startServer()
        defer { server.stop() }

        // Полный набор живых соединений: каждое уже ответило, значит принято и учтено
        var live = [TestClient]()
        for _ in 0..<MCPSocketServer.maxConnections {
            let client = try TestClient(path: socketPath)
            try client.send(#"{"cmd":"packs"}"# + "\n")
            #expect(object(client.readLine())?["ok"] as? Bool == true)
            live.append(client)
        }

        // Два лишних подряд: каждый получает одну строку отказа и конец потока
        for _ in 0..<2 {
            let extra = try TestClient(path: socketPath)
            let refusal = object(extra.readLine())
            #expect(refusal?["ok"] as? Bool == false)
            #expect((refusal?["error"] as? String)?.isEmpty == false)
            #expect(refusal?["language"] as? String == "ru")
            #expect(extra.isClosedByPeer())
        }

        // Живые соединения по-прежнему обслуживаются
        for client in live {
            try client.send(#"{"cmd":"packs"}"# + "\n")
            #expect(object(client.readLine())?["ok"] as? Bool == true)
        }

        // Один ушёл: место освобождается, отказанные в счёт не шли, новый клиент обслуживается
        live.removeLast().close()
        var served = false
        for _ in 0..<50 where !served {
            let next = try TestClient(path: socketPath)
            try? next.send(#"{"cmd":"packs"}"# + "\n")
            if object(next.readLine())?["data"] != nil {
                served = true
                live.append(next)
            } else {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        #expect(served)

        // И снова полный набор: следующий лишний опять получает отказ
        let extra = try TestClient(path: socketPath)
        #expect(object(extra.readLine())?["ok"] as? Bool == false)
        #expect(extra.isClosedByPeer())
    }

    @Test(.timeLimit(.minutes(1)))
    func слишкомДлинныйПутьНеЗапускаетСервер() async throws {
        let longPath = root.appendingPathComponent(String(repeating: "д", count: 60) + ".sock").path
        #expect(longPath.utf8.count > 103)
        let server = MCPSocketServer(path: longPath)
        server.start(door: await makeDoor())
        defer { server.stop() }

        #expect(!server.isRunning)
        #expect(!FileManager.default.fileExists(atPath: longPath))
    }
}

/// Простой клиент на POSIX-сокете с таймаутом чтения, чтобы сломанный сервер не повесил тест.
private final class TestClient {
    private var fd: Int32
    private var buffer = [UInt8]()

    struct Failure: Error { let message: String }

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw Failure(message: "connect errno \(errno)")
        }
    }

    deinit { close() }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    func send(_ text: String) throws {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
            guard written > 0 else { throw Failure(message: "write errno \(errno)") }
            offset += written
        }
    }

    func sendIgnoringErrors(_ text: String) {
        try? send(text)
    }

    private func setTimeout(_ seconds: Double) {
        var time = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Строка ответа без перевода строки или `nil`, если за отведённое время её нет.
    func readLine(timeout: Double = 10) -> String? {
        setTimeout(timeout)
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[..<index])
                buffer.removeSubrange(...index)
                return String(decoding: line, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[..<count])
        }
    }

    /// Сервер закрыл соединение: чтение отдаёт конец потока, а не таймаут.
    func isClosedByPeer(timeout: Double = 10) -> Bool {
        setTimeout(timeout)
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 { continue }
            if count == 0 { return true }
            return errno == ECONNRESET
        }
    }
}
