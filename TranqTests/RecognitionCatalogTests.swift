import Testing
import Foundation
@testable import Tranq

/// Каталог распознавания по замеру 25 ноября 2026, scripts/eval-asr.py.
struct RecognitionCatalogTests {

    /// Русский Whisper распознаёт по-русски: с `-l en` русская речь уходит в английский.
    @Test func russianTurboRecognizesRussian() {
        let model = ModelStore.shared.model(named: "ru_turbo")
        #expect(model?.languageCode == "ru")
        #expect(model?.isBundled == false)
        #expect(model?.downloadURL?.lastPathComponent == model?.fileName)
    }

    /// Английский Whisper остаётся английским, GigaAM остаётся моделью по умолчанию.
    @Test func existingModelsUnchanged() {
        #expect(ModelStore.shared.model(named: "en_turbo")?.languageCode == "en")
        #expect(ModelStore.catalog.first?.id == "ru_giga")
    }

    /// Файлы моделей не пересекаются: удаление одной не стирает другую.
    @Test func fileNamesAreDistinct() {
        let names = ModelStore.catalog.map(\.fileName)
        #expect(Set(names).count == names.count)
    }
}
