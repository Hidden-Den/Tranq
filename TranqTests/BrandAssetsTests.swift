import Testing
import AppKit
@testable import Tranq

/// Ресурсы бренда: буква Q для строки меню и логотипа.
struct BrandAssetsTests {
    @Test func menuBarGlyphExists() {
        #expect(NSImage(named: "MenuBarQ") != nil)
    }

    @Test func appLogoExists() {
        #expect(NSImage(named: "AppLogo") != nil)
    }

    @Test func appLogoIsTemplate() {
        #expect(NSImage(named: "AppLogo")?.isTemplate == true)
    }

    @Test func menuBarGlyphIsTemplate() {
        #expect(NSImage(named: "MenuBarQ")?.isTemplate == true)
    }

    @Test func menuBarGlyphHasMenuBarSize() {
        let glyph = BrandAssets.menuBarGlyph()
        #expect(glyph.isTemplate)
        #expect(glyph.size.height == 16)
        #expect(glyph.size.width > 0 && glyph.size.width < 16)
    }
}
