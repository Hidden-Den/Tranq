import Foundation

/// Снимок контекста, ждущий адрес вкладки. Не зависит от следующих записей.
struct FrozenDictationContext {
    let bundleId: String?
    let promptRequested: Bool
    fileprivate let hostTask: Task<String?, Never>?

    func resolve() async -> DictationContext {
        let host = await hostTask?.value
        return DictationContext(bundleId: bundleId, host: host, promptRequested: promptRequested)
    }
}

/// Снимает контекст диктовки при начале записи. Адрес вкладки читается в фоне,
/// чтобы запись стартовала без задержки.
final class DictationContextCapture {
    private let source: FocusedURLSource
    private let lock = NSLock()
    private var bundleId: String?
    private var promptRequested = false
    private var hostTask: Task<String?, Never>?
    private var generation = 0

    private let readDeadline: TimeInterval

    /// `readDeadline` — сколько ждать адрес вкладки; тесты увеличивают его, чтобы не зависеть от нагрузки.
    init(source: FocusedURLSource = AccessibilityURLSource(), readDeadline: TimeInterval = 0.3) {
        self.source = source
        self.readDeadline = readDeadline
    }

    /// `onHost` вызывается один раз, если запись за это время не сменилась новой.
    func begin(
        app: (pid: pid_t, bundleId: String?)?,
        promptRequested: Bool,
        readsHost: Bool = true,
        onHost: ((String?) -> Void)? = nil
    ) {
        let source = self.source
        let readDeadline = self.readDeadline
        let current = lock.withLock { () -> Int in
            generation += 1
            bundleId = app?.bundleId
            self.promptRequested = promptRequested
            return generation
        }
        // Без правил по сайтам адрес вкладки не нужен: чтение включает режим доступности у браузеров на Chromium
        guard readsHost, let app, BrowserURLReader.isBrowser(app.bundleId) else {
            lock.withLock { hostTask = nil }
            return
        }
        let task = Task<String?, Never> { [weak self] in
            let host = await BrowserURLReader.readHost(pid: app.pid, bundleId: app.bundleId, source: source, deadline: readDeadline)
            if let self, self.isCurrent(current) { onHost?(host) }
            return host
        }
        lock.withLock { hostTask = task }
    }

    /// Фиксирует контекст прямо сейчас; следующий `begin` его не меняет.
    func freeze() -> FrozenDictationContext {
        lock.withLock {
            FrozenDictationContext(bundleId: bundleId, promptRequested: promptRequested, hostTask: hostTask)
        }
    }

    func finish() async -> DictationContext {
        await freeze().resolve()
    }

    private func isCurrent(_ value: Int) -> Bool {
        lock.withLock { generation == value }
    }
}
