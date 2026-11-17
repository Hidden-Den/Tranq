import Testing
import Foundation
@testable import Tranq

/// Имя и идентификаторы после ребрендинга в Tranq.
struct BrandingTests {
    @Test func bundleIdentifierIsTranq() {
        #expect(Bundle.main.bundleIdentifier == "kozak-developer.Tranq")
    }

    @Test func bundleNameIsTranq() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "Tranq")
    }

    @Test func dataFolderNameIsTranq() {
        #expect(AppEnvironment.dataFolderName == "Tranq")
    }

    @Test func builtInPacksStillLoad() {
        #expect(DictionaryStore.loadPacks(from: .main).count == 10)
    }
}
