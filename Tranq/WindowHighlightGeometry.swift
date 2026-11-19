import Foundation
import CoreGraphics

/// Размеры рамки подсветки и пересчёт координат окна.
///
/// Accessibility отдаёт положение окна в своей системе координат: начало в левом верхнем
/// углу главного экрана, ось Y растёт вниз. AppKit считает от левого нижнего угла и вверх.
/// Без пересчёта рамка на втором мониторе уезжает, поэтому он вынесен сюда и покрыт тестами.
enum WindowHighlightGeometry {
    /// Толщина линии рамки.
    static let lineWidth: CGFloat = 2

    /// Радиус скругления. Accessibility его не сообщает, берём как у обычного окна macOS.
    static let cornerRadius: CGFloat = 10

    /// Запас вокруг окна, чтобы свечение не обрезалось краем панели.
    static let glowOutset: CGFloat = 26

    /// Прямоугольник окна в координатах экрана AppKit.
    static func screenRect(axOrigin: CGPoint, axSize: CGSize, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: axOrigin.x,
            y: primaryHeight - axOrigin.y - axSize.height,
            width: axSize.width,
            height: axSize.height
        )
    }

    /// Прямоугольник панели: окно плюс запас на свечение с каждой стороны.
    static func panelRect(for windowRect: CGRect) -> CGRect {
        windowRect.insetBy(dx: -glowOutset, dy: -glowOutset)
    }
}

/// Решение, показывать ли рамку в этом такте.
enum WindowHighlightPolicy {
    static func shouldShow(enabled: Bool, axTrusted: Bool, isOwnApp: Bool, windowRect: CGRect?) -> Bool {
        guard enabled, axTrusted, !isOwnApp else { return false }
        guard let windowRect else { return false }
        return windowRect.width > 0 && windowRect.height > 0
    }
}
