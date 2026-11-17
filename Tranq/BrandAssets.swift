import AppKit

/// Ресурсы бренда, которым нужен размер в точках.
enum BrandAssets {
    /// Высота значка в строке меню в точках.
    static let menuBarGlyphHeight: CGFloat = 16

    /// Буква Q для строки меню: шаблонное изображение, цвет подбирает система.
    /// Исходный контур большой, поэтому размер задаётся явно, с сохранением пропорций.
    static func menuBarGlyph() -> NSImage {
        guard let source = NSImage(named: "MenuBarQ"), source.size.height > 0 else { return NSImage() }
        let glyph = (source.copy() as? NSImage) ?? source
        let ratio = source.size.width / source.size.height
        glyph.size = NSSize(width: menuBarGlyphHeight * ratio, height: menuBarGlyphHeight)
        glyph.isTemplate = true
        return glyph
    }
}
