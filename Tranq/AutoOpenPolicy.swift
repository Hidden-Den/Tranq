import Foundation

/// Решает, нужно ли после диктовки переключать главное окно на историю.
enum AutoOpenPolicy {
    /// Экран меняется только когда окно скрыто: открытое окно остаётся на том экране, где оно сейчас.
    static func shouldSwitchToHistory(autoOpenEnabled: Bool, isWindowVisible: Bool) -> Bool {
        autoOpenEnabled && !isWindowVisible
    }
}

/// Видно ли главное окно на экране прямо сейчас.
enum WindowPresence {
    /// Окно на экране, только если оно показано, не свёрнуто в Dock и приложение не скрыто через ⌘H.
    /// `isVisible == nil` значит, что окна ещё нет: показывать нечего.
    static func isOnScreen(isVisible: Bool?, isMiniaturized: Bool, appIsHidden: Bool) -> Bool {
        (isVisible ?? false) && !isMiniaturized && !appIsHidden
    }
}

