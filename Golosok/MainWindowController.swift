import AppKit
import SwiftUI

/// Контроллер главного окна приложения.
/// Обеспечивает фоновую работу без закрытия процесса, скрытие в трей/строку статуса
/// и корректное восстановление окна при клике на иконку в Dock или строке меню.
final class MainWindowController: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = MainWindowController()
    
    private(set) weak var mainWindow: NSWindow?
    private weak var originalDelegate: NSWindowDelegate?
    @Published var isWindowVisible: Bool = true
    
    override init() {
        super.init()
    }
    
    /// Регистрирует главное окно приложения и подключает перехват закрытия.
    func register(window: NSWindow) {
        guard !(window is NSPanel), window.canBecomeKey else { return }
        
        if self.mainWindow !== window {
            self.mainWindow = window
            self.isWindowVisible = window.isVisible
            
            if window.delegate !== self {
                self.originalDelegate = window.delegate
                window.delegate = self
            }
        }
    }
    
    /// Разворачивает главное окно на передний план и делает его активным.
    func showMainWindow() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let window = self.mainWindow {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            } else if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeKey }) {
                self.register(window: window)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            self.isWindowVisible = true
        }
    }
    
    /// Скрывает главное окно без завершения работы приложения.
    func hideMainWindow() {
        DispatchQueue.main.async {
            self.mainWindow?.orderOut(nil)
            self.isWindowVisible = false
        }
    }
    
    // MARK: - NSWindowDelegate
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === mainWindow {
            sender.orderOut(nil)
            DispatchQueue.main.async {
                self.isWindowVisible = false
            }
            return false
        }
        return originalDelegate?.windowShouldClose?(sender) ?? true
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === mainWindow {
            DispatchQueue.main.async {
                self.isWindowVisible = true
            }
        }
        originalDelegate?.windowDidBecomeKey?(notification)
    }
    
    func windowDidResignKey(_ notification: Notification) {
        originalDelegate?.windowDidResignKey?(notification)
    }
    
    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(windowShouldClose(_:)) ||
           aSelector == #selector(windowDidBecomeKey(_:)) ||
           aSelector == #selector(windowDidResignKey(_:)) {
            return true
        }
        if super.responds(to: aSelector) {
            return true
        }
        return originalDelegate?.responds(to: aSelector) ?? false
    }
    
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if originalDelegate?.responds(to: aSelector) == true {
            return originalDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }
}

/// Вспомогательное NSView для надежной фиксации окна без лишних циклов перерисовки SwiftUI.
final class WindowDetectorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            MainWindowController.shared.register(window: window)
        }
    }
}

/// SwiftUI ViewModifier / Background для автоматической привязки NSWindow к MainWindowController.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDetectorView {
        WindowDetectorView()
    }
    
    func updateNSView(_ nsView: WindowDetectorView, context: Context) {}
}
