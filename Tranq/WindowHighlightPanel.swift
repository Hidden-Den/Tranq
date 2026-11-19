import SwiftUI
import AppKit
import ApplicationServices

/// Окно, вокруг которого рисуется рамка: процесс и его прямоугольник в координатах экрана.
struct HighlightTarget: Equatable {
    let pid: pid_t
    let windowRect: CGRect?
    let isMinimized: Bool
}

/// Салатовая неоновая рамка. Цвет единственный на всё приложение: это индикатор
/// состояния «идёт запись», внутри окон Tranq он не появляется.
struct WindowHighlightView: View {
    private static let line = Color(hex: "#CBFF6E")
    private static let glowNear = Color(hex: "#B6F040")
    private static let glowFar = Color(hex: "#9FE03A")

    @State private var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: WindowHighlightGeometry.cornerRadius, style: .continuous)
            .strokeBorder(Self.line, lineWidth: WindowHighlightGeometry.lineWidth)
            .shadow(color: Self.glowNear.opacity(0.8), radius: 7)
            .shadow(color: Self.glowFar.opacity(0.33), radius: 17)
            .padding(WindowHighlightGeometry.glowOutset)
            .opacity(dimmed ? 0.62 : 1.0)
            .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
    }
}

/// Ведёт рамку за фокусным окном переднего приложения, пока идёт диктовка.
///
/// Смену приложения ловит уведомление `NSWorkspace`: это мгновенно и бесплатно.
/// Положение и размер окна опрашиваются таймером, потому что приложения шлют
/// уведомления Accessibility о перемещении непоследовательно.
@MainActor
final class WindowHighlightManager {
    static let shared = WindowHighlightManager(targetProvider: WindowHighlightManager.accessibilityTarget)

    private static let tickInterval = 1.0 / 30.0
    private static let fadeDuration = 0.2

    private let targetProvider: () -> HighlightTarget?
    private let isEnabled: () -> Bool
    private let isAXTrusted: () -> Bool

    private var panel: NSPanel?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var lastPanelRect: CGRect?

    /// Растёт при каждом показе и скрытии. Отложенный orderOut после затухания
    /// срабатывает, только если за эти 0,2 с панель не показали заново.
    private var generation = 0

    /// После отпускания клавиши текст уходит в зафиксированное приложение,
    /// поэтому рамка перестаёт переезжать за передним окном.
    private var pinnedPid: pid_t?

    private(set) var isTracking = false
    private(set) var isPanelVisible = false

    var isPanelOnScreen: Bool { panel?.isVisible ?? false }

    init(
        targetProvider: @escaping () -> HighlightTarget?,
        isEnabled: @escaping () -> Bool = { AppPreferences.shared.windowHighlightEnabled },
        isAXTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.targetProvider = targetProvider
        self.isEnabled = isEnabled
        self.isAXTrusted = isAXTrusted
    }

    /// Вызовы из цикла записи: он не изолирован в MainActor, а панель живёт только там.
    /// Очередь, а не `Task`: порядок постановки нужен, иначе отмена и немедленный
    /// повторный старт могут поменяться местами.
    nonisolated static func beginTracking() {
        DispatchQueue.main.async { MainActor.assumeIsolated { shared.start() } }
    }

    nonisolated static func endTracking() {
        DispatchQueue.main.async { MainActor.assumeIsolated { shared.stop() } }
    }

    /// Запись окончена: дальше подсвечиваем только то приложение, в которое уйдёт текст.
    nonisolated static func pinTracking(to pid: pid_t) {
        DispatchQueue.main.async { MainActor.assumeIsolated { shared.pin(to: pid) } }
    }

    func pin(to pid: pid_t) {
        pinnedPid = pid
        tick()
    }

    /// Тестам нужен один такт без ожидания таймера.
    func tickForTesting() { tick() }

    func start() {
        guard !isTracking else { return }
        isTracking = true
        pinnedPid = nil

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }

        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }

        isTracking = false
        pinnedPid = nil
        hidePanel()
    }

    // MARK: - Такт

    private func tick() {
        // Настройка и права проверяются до обращения к Accessibility: иначе выключенная
        // подсветка всё равно стоила бы трёх обращений к чужому процессу на каждом такте.
        guard isEnabled(), isAXTrusted() else {
            hidePanel()
            return
        }

        let target = targetProvider()
        let isWrongApp = pinnedPid.map { $0 != target?.pid } ?? false
        let visible = !isWrongApp && WindowHighlightPolicy.shouldShow(
            enabled: true,
            axTrusted: true,
            isOwnApp: target?.pid == ProcessInfo.processInfo.processIdentifier,
            isMinimized: target?.isMinimized ?? false,
            windowRect: target?.windowRect
        )

        guard visible, let windowRect = target?.windowRect else {
            hidePanel()
            return
        }

        showPanel(at: WindowHighlightGeometry.panelRect(for: windowRect))
    }

    private func showPanel(at rect: CGRect) {
        let panel = existingOrNewPanel()
        if lastPanelRect != rect {
            panel.setFrame(rect, display: true)
            lastPanelRect = rect
        }

        guard !isPanelVisible else { return }
        isPanelVisible = true
        generation += 1
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1.0
        }
    }

    private func hidePanel() {
        guard isPanelVisible, let panel else { return }
        isPanelVisible = false
        generation += 1
        let hiddenAt = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // За время затухания панель могли показать заново: тогда убирать её нельзя.
                guard self?.generation == hiddenAt else { return }
                panel.orderOut(nil)
                self?.lastPanelRect = nil
            }
        }
    }

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hostingView = NSHostingView(rootView: WindowHighlightView())
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView

        self.panel = panel
        return panel
    }

    // MARK: - Источник цели

    /// Фокусное окно переднего приложения. Любая неудача даёт цель без прямоугольника:
    /// такт повторяется 30 раз в секунду, записывать это в журнал нельзя.
    private static func accessibilityTarget() -> HighlightTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let window = focusedWindow(pid: pid)
        return HighlightTarget(
            pid: pid,
            windowRect: window.map(windowRect(of:)) ?? nil,
            isMinimized: window.map(isMinimized(_:)) ?? false
        )
    }

    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowValue = windowRef,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        return (windowValue as! AXUIElement)
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }

    private static func windowRect(of window: AXUIElement) -> CGRect? {
        guard let positionValue = axValue(of: window, attribute: kAXPositionAttribute),
              let sizeValue = axValue(of: window, attribute: kAXSizeAttribute),
              let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                ?? NSScreen.screens.first?.frame.height else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }

        return WindowHighlightGeometry.screenRect(axOrigin: origin, axSize: size, primaryHeight: primaryHeight)
    }

    private static func axValue(of element: AXUIElement, attribute: String) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
