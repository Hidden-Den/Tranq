import Foundation
import ApplicationServices

/// Источник адреса активной вкладки. Синхронный и может блокироваться, поэтому вызывается не с главного потока.
protocol FocusedURLSource: Sendable {
    func focusedURL(pid: pid_t, bundleId: String) -> URL?
}

enum BrowserURLReader {
    static let chromiumBundleIds: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "ru.yandex.desktop.yandex-browser",
    ]

    static let browserBundleIds: Set<String> = chromiumBundleIds.union([
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox",
    ])

    static func isBrowser(_ bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return browserBundleIds.contains(bundleId)
    }

    /// Домен активной вкладки. Не браузер, ошибка или молчание браузера дольше `deadline` дают `nil`.
    static func readHost(
        pid: pid_t,
        bundleId: String?,
        source: FocusedURLSource,
        deadline: TimeInterval = 0.3
    ) async -> String? {
        guard let bundleId, isBrowser(bundleId) else { return nil }
        return await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            // Чтение блокирующее, поэтому идёт на отдельной очереди, а не в пуле Swift Concurrency
            DispatchQueue.global(qos: .userInitiated).async {
                let url = source.focusedURL(pid: pid, bundleId: bundleId)
                gate.resume(url.flatMap { DomainNormalizer.host(from: $0.absoluteString) })
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
                gate.resume(nil)
            }
        }
    }
}

/// Возобновляет продолжение один раз: побеждает тот, кто пришёл первым, чтение или ожидание.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: String?) {
        let pending = lock.withLock { () -> CheckedContinuation<String?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// Поиск веб-области страницы в дереве Accessibility. Обобщён по типу узла, чтобы проверяться без браузера.
enum AXWebAreaSearch {
    /// Обход в ширину. Страницей считается веб-область с адресом http или https: панели разработчика
    /// и инспектор браузера пропускаются. Обход прекращается по числу узлов и по времени,
    /// потому что медленный браузер иначе держал бы поток, когда результат уже никому не нужен.
    static func firstPageURL<Node>(
        root: Node,
        maxVisited: Int,
        budget: TimeInterval,
        now: () -> Date = Date.init,
        role: (Node) -> String?,
        children: (Node) -> [Node],
        url: (Node) -> URL?
    ) -> URL? {
        let start = now()
        var queue = [root]
        var index = 0
        while index < queue.count, index < maxVisited {
            if now().timeIntervalSince(start) > budget { return nil }
            let current = queue[index]
            index += 1
            if role(current) == "AXWebArea", let candidate = url(current), isPage(candidate) {
                return candidate
            }
            queue.append(contentsOf: children(current))
        }
        return nil
    }

    private static func isPage(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

/// Читает адрес из дерева Accessibility: первая веб-область страницы в сфокусированном окне.
struct AccessibilityURLSource: FocusedURLSource {
    private static let maxVisited = 400
    private static let walkBudget: TimeInterval = 0.3
    private static let messagingTimeout: Float = 0.25

    func focusedURL(pid: pid_t, bundleId: String) -> URL? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        if BrowserURLReader.chromiumBundleIds.contains(bundleId) {
            ManualAccessibilityTracker.shared.enableOnce(for: app, pid: pid)
        }
        guard let window = Self.element(app, kAXFocusedWindowAttribute) else { return nil }
        // Таймаут задан у приложения, но элементы, которые оно вернуло, берут общий, около шести секунд
        AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)

        return AXWebAreaSearch.firstPageURL(
            root: window,
            maxVisited: Self.maxVisited,
            budget: Self.walkBudget,
            role: { Self.string($0, kAXRoleAttribute) },
            children: { parent in
                let kids = Self.children(parent)
                kids.forEach { AXUIElementSetMessagingTimeout($0, Self.messagingTimeout) }
                return kids
            },
            url: { Self.url($0) }
        )
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func url(_ element: AXUIElement) -> URL? {
        guard let value = attribute(element, "AXURL") else { return nil }
        if let url = value as? URL { return url }
        if let text = value as? String { return URL(string: text) }
        return nil
    }
}

/// Chromium строит дерево Accessibility только после просьбы, и просить достаточно один раз на процесс.
private final class ManualAccessibilityTracker: @unchecked Sendable {
    static let shared = ManualAccessibilityTracker()
    private let lock = NSLock()
    private var enabledPids = Set<pid_t>()

    func enableOnce(for app: AXUIElement, pid: pid_t) {
        let isNew = lock.withLock { enabledPids.insert(pid).inserted }
        guard isNew else { return }
        let status = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Неудачную просьбу повторит следующая диктовка
        if status != .success { _ = lock.withLock { enabledPids.remove(pid) } }
    }
}
