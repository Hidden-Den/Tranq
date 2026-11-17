import Testing
import AppKit
@testable import Tranq

/// Ресурсы бренда: строчная q для строки меню.
struct BrandAssetsTests {
    @Test func menuBarMarkExists() {
        #expect(NSImage(named: "MenuBarMark") != nil)
    }

    @Test func menuBarMarkIsTemplate() {
        #expect(NSImage(named: "MenuBarMark")?.isTemplate == true)
    }

    @Test func menuBarMarkHasMenuBarSize() {
        let glyph = BrandAssets.menuBarMark()
        #expect(glyph.isTemplate)
        #expect(glyph.size.height == 16)
        #expect(glyph.size.width > 0 && glyph.size.width < 32)
    }

    /// Одна строчная q даёт отношение сторон около 0.78, монограмма Tq около 0.93.
    @Test func menuBarMarkIsSingleLetterQ() {
        let glyph = BrandAssets.menuBarMark()
        #expect(glyph.size.width / glyph.size.height < 0.85)
    }
}
