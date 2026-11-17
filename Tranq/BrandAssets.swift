import AppKit

/// Ресурсы бренда, которым нужен размер в точках.
enum BrandAssets {
    /// Высота знака в строке меню в точках.
    static let menuBarMarkHeight: CGFloat = 16

    /// Строчная q для строки меню: шаблонное изображение, цвет подбирает система.
    /// Исходный контур большой, поэтому размер задаётся явно, с сохранением пропорций.
    static func menuBarMark() -> NSImage {
        guard let source = NSImage(named: "MenuBarMark"), source.size.height > 0 else { return NSImage() }
        let glyph = (source.copy() as? NSImage) ?? source
        let ratio = source.size.width / source.size.height
        glyph.size = NSSize(width: menuBarMarkHeight * ratio, height: menuBarMarkHeight)
        glyph.isTemplate = true
        return glyph
    }
}
