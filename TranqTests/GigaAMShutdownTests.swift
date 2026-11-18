import Testing
import Foundation
@testable import Tranq

/// Всё, что трогает общий движок GigaAM, идёт по очереди под одним родителем:
/// `.serialized` упорядочивает только вложенные наборы, и выход из приложения не должен
/// вклиниваться в распознавание из соседнего набора.
@Suite(.serialized)
enum GigaAMEngineTests {
    /// Выход из приложения: Metal не любит, когда модель ещё жива в момент освобождения устройства.
    @Suite
    struct Shutdown {
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

    /// Сквозное распознавание: системный голос синтезирует русскую речь, встроенный движок её распознаёт.
    @Suite
    struct Integration {
        /// Пропускается, если в бандле нет модели или в системе нет русского голоса, например в CI.
        @Test(.enabled(if: ModelStore.shared.localModelPath(for: RecognitionModel.russianGigaAM.id) != nil, "нет модели gigaam.gguf"))
        func recognizesSynthesizedRussianSpeech() throws {
            let aiff = TempFiles.makeURL(prefix: "say", ext: "aiff")
            defer { TempFiles.remove(aiff) }

            guard let say = ProcessRunner.run("/usr/bin/say", arguments: ["-v", "Milena", "-o", aiff.path, "Завтра в десять утра созвонимся с командой"], timeout: 30),
                  say.succeeded else { return }

            let samples = try #require(AudioPCM.loadSamples(from: aiff))

            let result = GigaAMEngine.shared.recognize(samples: samples)
            let text = result.text.lowercased()
            #expect(text.contains("завтра"), "распознано: \(result.text)")
            #expect(text.contains("команд"), "распознано: \(result.text)")
            #expect(!result.words.isEmpty)
            #expect(result.words.allSatisfy { $0.end >= $0.start })
        }
    }
}
