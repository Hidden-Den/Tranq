import Testing
import Foundation
@testable import Tranq

/// Всё, что трогает общий движок GigaAM, идёт по очереди под одним родителем:
/// `.serialized` упорядочивает только вложенные наборы, и выход из приложения не должен
/// вклиниваться в распознавание из соседнего набора.
@Suite(.serialized)
enum TranscribeEngineTests {
    /// Выход из приложения: Metal не любит, когда модель ещё жива в момент освобождения устройства.
    @Suite
    struct Shutdown {
        @Test(.enabled(if: ModelStore.shared.localModelPath(for: RecognitionModel.russianGigaAM.id) != nil, "нет модели gigaam.gguf"))
        func shutdownFreesTheLoadedModel() {
            _ = TranscribeEngine.gigaAM.recognize(samples: [Float](repeating: 0, count: 16_000))
            #expect(TranscribeEngine.gigaAM.isModelLoaded)

            TranscribeEngine.gigaAM.shutdown()
            #expect(!TranscribeEngine.gigaAM.isModelLoaded)
        }

        @Test func shutdownWithoutLoadedModelIsSafe() {
            TranscribeEngine.gigaAM.shutdown()
            #expect(!TranscribeEngine.gigaAM.isModelLoaded)
        }
    }

    /// Какие модели работают в процессе, а какие через whisper-cli.
    @Suite
    struct Routing {
        @Test func russianModelsRunInProcess() {
            #expect(TranscribeEngine.engine(for: .russianGigaAM) === TranscribeEngine.gigaAM)
            #expect(TranscribeEngine.engine(for: .russianTurbo) === TranscribeEngine.russianTurbo)
        }

        @Test func englishWhisperStaysOnCLI() {
            #expect(TranscribeEngine.engine(for: .englishTurbo) == nil)
            #expect(TranscribeEngine.engine(for: .englishMedium) == nil)
        }

        /// Whisper отдаёт метки фраз: слова делят время фразы по порядку и без нахлёста.
        @Test func segmentWordsSplitSegmentTime() {
            let words = TranscribeEngine.segmentWords(" Задеплой фичи на стейджинг", from: 1.0, to: 3.0)
            #expect(words.map(\.text) == ["Задеплой", "фичи", "на", "стейджинг"])
            #expect(words.first?.start == 1.0)
            #expect(abs((words.last?.end ?? 0) - 3.0) < 0.01)
            #expect(zip(words, words.dropFirst()).allSatisfy { $0.end <= $1.start + 0.0001 })
        }

        @Test func emptySegmentGivesNoWords() {
            #expect(TranscribeEngine.segmentWords("  ", from: 0, to: 1).isEmpty)
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

            let result = TranscribeEngine.gigaAM.recognize(samples: samples)
            let text = result.text.lowercased()
            #expect(text.contains("завтра"), "распознано: \(result.text)")
            #expect(text.contains("команд"), "распознано: \(result.text)")
            #expect(!result.words.isEmpty)
            #expect(result.words.allSatisfy { $0.end >= $0.start })
        }

        /// Русский Whisper в процессе: та же фраза, язык русский, слова с метками.
        /// Пропускается без скачанной модели ggml-large-v3-turbo-q5_0.bin.
        @Test(.enabled(if: ModelStore.shared.localModelPath(for: RecognitionModel.russianTurbo.id) != nil, "нет модели Whisper turbo"))
        func whisperRecognizesSynthesizedRussianSpeech() throws {
            let aiff = TempFiles.makeURL(prefix: "say", ext: "aiff")
            defer { TempFiles.remove(aiff) }

            guard let say = ProcessRunner.run("/usr/bin/say", arguments: ["-v", "Milena", "-o", aiff.path, "Завтра в десять утра созвонимся с командой"], timeout: 30),
                  say.succeeded else { return }

            let samples = try #require(AudioPCM.loadSamples(from: aiff))
            defer { TranscribeEngine.russianTurbo.shutdown() }

            let result = TranscribeEngine.russianTurbo.recognize(samples: samples)
            let text = result.text.lowercased()
            #expect(text.contains("завтра"), "распознано: \(result.text)")
            #expect(text.contains("команд"), "распознано: \(result.text)")
            #expect(!result.words.isEmpty)
            #expect(result.words.allSatisfy { $0.end >= $0.start })
            #expect(TranscribeEngine.russianTurbo.isModelLoaded)
        }

        /// На тишине Whisper turbo пишет «Продолжение следует...» из титров. В диктовку это попадать не должно.
        @Test(.enabled(if: ModelStore.shared.localModelPath(for: RecognitionModel.russianTurbo.id) != nil, "нет модели Whisper turbo"))
        func whisperSilenceGivesNoText() {
            defer { TranscribeEngine.russianTurbo.shutdown() }
            let result = TranscribeEngine.russianTurbo.recognize(samples: [Float](repeating: 0, count: 11_200))
            #expect(result.text.isEmpty, "распознано: \(result.text)")
            #expect(result.words.isEmpty)
        }
    }

    /// Фразы, которые Whisper выдумывает на тишине: подписи из титров видео.
    @Suite
    struct Hallucinations {
        @Test(arguments: [
            "Продолжение следует...",
            " продолжение следует",
            "Субтитры сделал DimaTorzok",
            "Субтитры создавал DimaTorzok",
            "Редактор субтитров А.Синецкая Корректор А.Егорова",
            "Спасибо за просмотр!",
        ])
        func knownPhraseIsDropped(_ segment: String) {
            #expect(TranscribeEngine.isHallucination(segment))
        }

        @Test(arguments: [
            "Продолжение следует в понедельник, обсудим на созвоне.",
            "Включи субтитры к видео",
            "Спасибо.",
            "Привет, сегодня обсудим план релиза.",
        ])
        func realSpeechIsKept(_ segment: String) {
            #expect(!TranscribeEngine.isHallucination(segment))
        }
    }
}
