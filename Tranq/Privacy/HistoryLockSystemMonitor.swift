import AppKit
import Combine

/// Системные входы замка: сон Mac, видимость главного окна и редкий таймер.
/// Только переводит события macOS в вызовы `HistoryLockCoordinator`, правил здесь нет.
@MainActor
final class HistoryLockSystemMonitor {
    /// Как часто проверять пятнадцать минут без окна. Таймер идёт только при открытой истории.
    static let tickInterval: TimeInterval = 30

    private let coordinator: HistoryLockCoordinator
    private let windowOnScreen: () -> Bool
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?

    init(coordinator: HistoryLockCoordinator,
         windowOnScreen: @escaping () -> Bool = { MainWindowController.shared.isMainWindowOnScreen }) {
        self.coordinator = coordinator
        self.windowOnScreen = windowOnScreen
    }

    /// Звать после регистрации главного окна: сразу сообщает начальную видимость.
    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.coordinator.noteSystemWillSleep() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.coordinator.noteSystemDidWake() }
        })

        // Любое из этих событий может сменить видимость окна; сама видимость читается заново.
        let center = NotificationCenter.default
        let visibilityEvents: [Notification.Name] = [
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSApplication.didBecomeActiveNotification,
        ]
        for name in visibilityEvents {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reportVisibility() }
            })
        }
        // Закрытие окна идёт через orderOut без уведомления: его видно по флагу контроллера.
        MainWindowController.shared.$isWindowVisible
            .sink { [weak self] _ in Task { @MainActor in self?.reportVisibility() } }
            .store(in: &cancellables)

        coordinator.$state
            .sink { [weak self] state in Task { @MainActor in self?.updateTimer(for: state) } }
            .store(in: &cancellables)

        reportVisibility()
    }

    private func reportVisibility() {
        coordinator.noteWindowVisibility(windowOnScreen())
    }

    private func updateTimer(for state: HistoryLockState) {
        if state == .unlocked {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.reportVisibility()
                    self?.coordinator.tick()
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
}
