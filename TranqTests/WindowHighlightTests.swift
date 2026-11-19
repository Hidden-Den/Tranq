import Testing
import Foundation
@testable import Tranq

struct WindowHighlightGeometryTests {
    /// Главный экран высотой 1000: окно в 100 пунктах от верхнего края AX
    /// начинается в 700 пунктах от нижнего края AppKit.
    @Test func convertsAccessibilityOriginToScreenOrigin() {
        let rect = WindowHighlightGeometry.screenRect(
            axOrigin: CGPoint(x: 50, y: 100),
            axSize: CGSize(width: 400, height: 200),
            primaryHeight: 1000
        )
        #expect(rect == CGRect(x: 50, y: 700, width: 400, height: 200))
    }

    /// Review Focus 2: монитор над главным даёт отрицательный y в координатах AX.
    @Test func handlesDisplayAbovePrimary() {
        let rect = WindowHighlightGeometry.screenRect(
            axOrigin: CGPoint(x: 0, y: -500),
            axSize: CGSize(width: 300, height: 300),
            primaryHeight: 1000
        )
        #expect(rect == CGRect(x: 0, y: 1200, width: 300, height: 300))
    }

    /// Review Focus 2: монитор левее главного даёт отрицательный x, он сохраняется как есть.
    @Test func handlesDisplayLeftOfPrimary() {
        let rect = WindowHighlightGeometry.screenRect(
            axOrigin: CGPoint(x: -1200, y: 0),
            axSize: CGSize(width: 600, height: 400),
            primaryHeight: 1000
        )
        #expect(rect == CGRect(x: -1200, y: 600, width: 600, height: 400))
    }

    @Test func panelIsOutsetOnEverySide() {
        let panel = WindowHighlightGeometry.panelRect(for: CGRect(x: 100, y: 100, width: 400, height: 200))
        let outset = WindowHighlightGeometry.glowOutset
        #expect(panel == CGRect(x: 100 - outset, y: 100 - outset,
                                width: 400 + outset * 2, height: 200 + outset * 2))
    }
}

struct WindowHighlightPolicyTests {
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 300)

    @Test func showsForForeignWindow() {
        #expect(WindowHighlightPolicy.shouldShow(enabled: true, axTrusted: true, isOwnApp: false, windowRect: rect) == true)
    }

    @Test func hiddenWhenSettingOff() {
        #expect(WindowHighlightPolicy.shouldShow(enabled: false, axTrusted: true, isOwnApp: false, windowRect: rect) == false)
    }

    /// Review Focus 1: без прав Accessibility рамки нет.
    @Test func hiddenWithoutAccessibility() {
        #expect(WindowHighlightPolicy.shouldShow(enabled: true, axTrusted: false, isOwnApp: false, windowRect: rect) == false)
    }

    /// Review Focus 4: себя не подсвечиваем.
    @Test func hiddenForOwnApp() {
        #expect(WindowHighlightPolicy.shouldShow(enabled: true, axTrusted: true, isOwnApp: true, windowRect: rect) == false)
    }

    /// Review Focus 3: фокусное окно не определилось.
    @Test func hiddenWithoutWindow() {
        #expect(WindowHighlightPolicy.shouldShow(enabled: true, axTrusted: true, isOwnApp: false, windowRect: nil) == false)
    }

    @Test func hiddenForEmptyWindow() {
        #expect(WindowHighlightPolicy.shouldShow(enabled: true, axTrusted: true, isOwnApp: false, windowRect: .zero) == false)
    }
}

struct WindowHighlightPreferenceTests {
    @Test func defaultsToOnWhenNothingStored() {
        let d = UserDefaults(suiteName: "tranq-highlight-\(UUID().uuidString)")!
        #expect(AppPreferences.windowHighlightEnabled(in: d) == true)
    }

    @Test func storedValueWins() {
        let d = UserDefaults(suiteName: "tranq-highlight-\(UUID().uuidString)")!
        d.set(false, forKey: "windowHighlightEnabled")
        #expect(AppPreferences.windowHighlightEnabled(in: d) == false)
    }
}
