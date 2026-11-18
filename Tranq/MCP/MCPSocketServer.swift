import Foundation

/// Локальный Unix-сокет двери для `tranq-mcp`: принимает соединения, читает строки запросов,
/// отдаёт каждую двери и пишет ответ обратно тому же клиенту. Протокол — `mcp/PROTOCOL.md`.
///
/// Сокет живёт, пока запущено приложение, независимо от переключателей доступа: отказы выдаёт дверь.
/// POSIX-сокеты выбраны ради прав `0600` без окна: файл появляется уже с ними благодаря `umask` вокруг `bind`.
///
/// Потоки: приём идёт на своей последовательной очереди, каждое соединение — отдельная задача
/// на параллельной очереди, поэтому клиенты не ждут друг друга. Дверь сама уходит на главный поток
/// и ждёт его там, поэтому её никогда не зовут под замком, а `stop()` ничего не ждёт:
/// он закрывает приёмник, обрывает соединения через `shutdown` и удаляет файл.
final class MCPSocketServer: @unchecked Sendable {
    static let shared = MCPSocketServer()

    /// Путь сокета в папке данных приложения.
    static var socketURL: URL {
        AppEnvironment.dataDirectory.appendingPathComponent("mcp.sock")
    }

    /// Предел строки запроса: длиннее — отказ и закрытое соединение.
    static let maxLineBytes = 1 << 20
    /// Предел живых соединений. Каждое держит поток общего пула GCD, от которого зависят таймауты диктовки,
    /// поэтому утекающий клиент не должен занять его целиком. Лишнее соединение получает отказ и закрывается.
    static let maxConnections = 8
    /// Столько байт пути помещается в `sockaddr_un.sun_path` вместе с завершающим нулём.
    static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    private let path: String
    private let lock = NSLock()
    private let acceptQueue = DispatchQueue(label: "Tranq.MCPSocketServer.accept")
    private let connectionQueue = DispatchQueue(label: "Tranq.MCPSocketServer.connection", attributes: .concurrent)

    // Под замком
    private var acceptSource: DispatchSourceRead?
    private var connections = Set<Int32>()

    /// `path` подменяется в тестах, чтобы не трогать сокет приложения.
    init(path: String = MCPSocketServer.socketURL.path) {
        self.path = path
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return acceptSource != nil
    }

    // MARK: - Запуск и остановка

    func start(door: MCPDoor) {
        lock.lock(); defer { lock.unlock() }
        guard acceptSource == nil else { return }

        guard path.utf8.count <= Self.maxPathBytes else {
            AppLogger.shared.warn("MCP", "Путь сокета слишком длинный, сервер не запущен",
                                  details: "\(path.utf8.count) байт при пределе \(Self.maxPathBytes): \(path)")
            return
        }
        guard let listener = openListener() else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: listener, door: door) }
        source.setCancelHandler { Darwin.close(listener) }
        acceptSource = source
        source.resume()
        AppLogger.shared.info("MCP", "Сокет двери открыт", details: path)
    }

    /// Можно звать с любого потока, в том числе с главного: ничего не ждёт.
    func stop() {
        lock.lock()
        let source = acceptSource
        acceptSource = nil
        let live = connections
        lock.unlock()

        guard let source else { return }
        source.cancel()
        // Соединение закрывает свой дескриптор само, когда его чтение увидит конец потока:
        // так дескриптор не освободится, пока задача соединения ещё работает с ним.
        for fd in live { shutdown(fd, SHUT_RDWR) }
        unlink(path)
        AppLogger.shared.info("MCP", "Сокет двери закрыт")
    }

    /// Создаёт, привязывает и слушает сокет. Зовётся под замком.
    private func openListener() -> Int32? {
        // Файл от прошлого запуска мешает `bind`
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            AppLogger.shared.error("MCP", "Не удалось создать сокет", details: "errno \(errno)")
            return nil
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        // Файл сокета сразу появляется с правами 0600: окна с более широкими правами нет
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let bindError = errno
        umask(previousMask)

        guard bound == 0 else {
            AppLogger.shared.error("MCP", "Не удалось привязать сокет", details: "errno \(bindError): \(path)")
            Darwin.close(fd)
            return nil
        }
        guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            AppLogger.shared.error("MCP", "Не удалось открыть сокет", details: "errno \(errno): \(path)")
            Darwin.close(fd)
            unlink(path)
            return nil
        }
        // Приём неблокирующий: источник будит очередь, а цикл забирает всех ждущих
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    // MARK: - Соединения

    private func acceptPending(on listener: Int32, door: MCPDoor) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            // Клиент, ушедший посреди ответа, не роняет приложение сигналом
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            // Проверка предела и запись соединения под одним замком: гонки между ними нет
            lock.lock()
            let running = acceptSource != nil
            let admitted = running && connections.count < Self.maxConnections
            if admitted { connections.insert(fd) }
            lock.unlock()
            guard running else {
                Darwin.close(fd)
                return
            }
            guard admitted else {
                // Сокет ещё неблокирующий, как приёмник: не влезло сразу — просто закрываем, приём не ждёт
                let bytes = Array((Self.refusal(String(localized: "Слишком много соединений. Закройте лишние и повторите."),
                                                language: door.language) + "\n").utf8)
                _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
                Darwin.close(fd)
                continue
            }
            // Принятый сокет наследует неблокирующий режим приёмника, соединению он не нужен
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            connectionQueue.async { [weak self] in
                self?.serve(fd, door: door)
                self?.finish(fd)
            }
        }
    }

    private func finish(_ fd: Int32) {
        lock.lock()
        connections.remove(fd)
        lock.unlock()
        Darwin.close(fd)
    }

    /// Читает строки до конца потока, ошибки или слишком длинной строки. Без замка: дверь ждёт главный поток.
    private func serve(_ fd: Int32, door: MCPDoor) {
        var pending = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(contentsOf: chunk[..<count])

            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                var line = pending[start..<newline]
                start = newline + 1
                if line.last == 0x0D { line = line.dropLast() }
                guard line.count <= Self.maxLineBytes else {
                    _ = write(Self.oversizedAnswer(language: door.language), to: fd)
                    return
                }
                // Пустая строка пропускается без ответа
                guard !line.isEmpty else { continue }
                let answer = door.handle(line: String(decoding: line, as: UTF8.self))
                guard write(answer, to: fd) else { return }
            }
            pending.removeSubrange(..<start)
            if pending.count > Self.maxLineBytes {
                _ = write(Self.oversizedAnswer(language: door.language), to: fd)
                return
            }
        }
    }

    /// Пишет ответ и перевод строки целиком. `false` — клиент ушёл.
    private func write(_ answer: String, to fd: Int32) -> Bool {
        let bytes = Array((answer + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            // MSG_NOSIGNAL вдобавок к SO_NOSIGPIPE: запись в ушедшего клиента даёт EPIPE, а не сигнал
            let written = bytes[offset...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    /// Отказ на слишком длинную строку собирается без двери: строку ей не отдают.
    static func oversizedAnswer(language: DictionaryLanguage) -> String {
        refusal(String(localized: "Запрос длиннее 1 МиБ. Разбейте его на части."), language: language)
    }

    /// Отказ самого сокета в форме ответа двери: `ok: false`, текст и язык.
    static func refusal(_ text: String, language: DictionaryLanguage) -> String {
        let object: [String: Any] = [
            "ok": false,
            "error": text,
            "language": language.rawValue,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{\"ok\":false}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
