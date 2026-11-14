import SwiftUI
import AppKit

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "system"
    case dark = "dark"
    case light = "light"
    
    var id: String { rawValue }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
    
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
}

final class ThemeSettings: ObservableObject {
    static let shared = ThemeSettings()
    
    @AppStorage("appTheme") var rawTheme: String = AppTheme.system.rawValue {
        didSet {
            apply()
        }
    }
    
    var current: AppTheme {
        AppTheme(rawValue: rawTheme) ?? .system
    }
    
    private init() {
        apply()
    }
    
    func apply() {
        DispatchQueue.main.async {
            NSApp.appearance = self.current.nsAppearance
            if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.styleMask.contains(.titled) && !$0.className.contains("StatusBar") }) {
                window.appearance = self.current.nsAppearance
                let isDark = (self.current.nsAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                window.backgroundColor = isDark ? .black : .white
            }
        }
    }
    
    func select(_ theme: AppTheme) {
        rawTheme = theme.rawValue
        apply()
    }
}
