import Testing
import SwiftUI
import AppKit
@testable import Tranq

/// Шрифты бренда: Inter для интерфейса и Knewave для названия.
struct BrandFontsTests {
    private let interNames = ["Inter-Regular", "Inter-Medium", "Inter-SemiBold", "Inter-Bold"]

    @Test func registersAllBundledFonts() {
        #expect(BrandFonts.registerAll() == 5)
    }

    @Test func fontsAreAvailableAfterRegistration() {
        _ = BrandFonts.registerAll()
        for name in interNames + [BrandFonts.knewaveName] {
            #expect(NSFont(name: name, size: 13) != nil, "нет шрифта \(name)")
        }
    }

    @Test func interNameCoversEveryWeight() {
        let weights: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        for weight in weights {
            #expect(interNames.contains(BrandFonts.interName(for: weight)))
        }
        #expect(BrandFonts.interName(for: .light) == "Inter-Regular")
        #expect(BrandFonts.interName(for: .medium) == "Inter-Medium")
        #expect(BrandFonts.interName(for: .semibold) == "Inter-SemiBold")
        #expect(BrandFonts.interName(for: .black) == "Inter-Bold")
    }

    @Test func registeringEmptyBundleReturnsZero() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("empty-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BrandFonts.registerAll(in: try #require(Bundle(path: dir.path))) == 0)
    }

    @Test func onlyDefaultDesignUsesInter() {
        #expect(BrandFonts.usesInter(for: .default))
        #expect(!BrandFonts.usesInter(for: .monospaced))
        #expect(!BrandFonts.usesInter(for: .rounded))
        #expect(!BrandFonts.usesInter(for: .serif))
    }
}
