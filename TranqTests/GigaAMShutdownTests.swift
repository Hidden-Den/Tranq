import Testing
@testable import Tranq

/// Выход из приложения: Metal не любит, когда модель ещё жива в момент освобождения устройства.
/// Тесты идут по очереди: оба трогают общий движок.
@Suite(.serialized)
struct GigaAMShutdownTests {
    @Test(.enabled(if: ModelStore.shared.localModelPath(for: RecognitionModel.russianGigaAM.id) != nil, "нет модели gigaam.gguf"))
    func shutdownFreesTheLoadedModel() {
        _ = GigaAMEngine.shared.recognize(samples: [Float](repeating: 0, count: 16_000))
        #expect(GigaAMEngine.shared.isModelLoaded)

        GigaAMEngine.shared.shutdown()
        #expect(!GigaAMEngine.shared.isModelLoaded)
    }

    @Test func shutdownWithoutLoadedModelIsSafe() {
        GigaAMEngine.shared.shutdown()
        #expect(!GigaAMEngine.shared.isModelLoaded)
    }
}
