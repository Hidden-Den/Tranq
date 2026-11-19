import SwiftUI
import AppKit
import ApplicationServices

/// Окно, вокруг которого рисуется рамка: процесс и его прямоугольник в координатах экрана.
struct HighlightTarget: Equatable {
    let pid: pid_t
    let windowRect: CGRect?
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
    private var panel: NSPanel?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    private(set) var isTracking = false
    private(set) var isPanelVisible = false

    init(targetProvider: @escaping () -> HighlightTarget?) {
        self.targetProvider = targetProvider
    }

    func start() {
        guard !isTracking else { return }
        isTracking = true

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
        hidePanel()
    }

    // MARK: - Такт

    private func tick() {
        let target = targetProvider()
        let visible = WindowHighlightPolicy.shouldShow(
            enabled: AppPreferences.shared.windowHighlightEnabled,
            axTrusted: AXIsProcessTrusted(),
            isOwnApp: target?.pid == ProcessInfo.processInfo.processIdentifier,
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
        panel.setFrame(rect, display: true)

        guard !isPanelVisible else { return }
        isPanelVisible = true
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0.0
        } completionHandler: {
            panel.orderOut(nil)
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
        return HighlightTarget(pid: pid, windowRect: focusedWindowRect(pid: pid))
    }

    private static func focusedWindowRect(pid: pid_t) -> CGRect? {
        let application = AXUIElementCreateApplication(pid)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowValue = windowRef,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        let window = windowValue as! AXUIElement

        guard let positionValue = axValue(of: window, attribute: kAXPositionAttribute),
              let sizeValue = axValue(of: window, attribute: kAXSizeAttribute),
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }

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
