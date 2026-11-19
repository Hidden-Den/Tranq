import Foundation

/// Решает, нужно ли после диктовки переключать главное окно на историю.
enum AutoOpenPolicy {
    /// Экран меняется только когда окно скрыто: открытое окно остаётся на том экране, где оно сейчас.
    static func shouldSwitchToHistory(autoOpenEnabled: Bool, isWindowVisible: Bool) -> Bool {
        autoOpenEnabled && !isWindowVisible
    }
}
