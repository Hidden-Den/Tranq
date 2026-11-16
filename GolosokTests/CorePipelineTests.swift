import Testing
import Foundation
@testable import Golosok

// MARK: - Тайминги слов

struct WordTimingsTests {
    @Test func assemblesSentencePieceTokensIntoWords() {
        let tokens: [(text: String, start: Double, end: Double)] = [
            ("▁Че", 0.40, 0.44), ("ре", 0.52, 0.56), ("з", 0.60, 0.64),
            ("▁не", 0.72, 0.76), ("дел", 0.80, 0.84), ("ю", 0.92, 0.96),
            ("[_blank_]", 1.0, 1.0), ("▁надо", 1.04, 1.08)
        ]
        let words = WordTimings.assemble(tokens: tokens)
        #expect(words.map(\.text) == ["Через", "неделю", "надо"])
        #expect(words[0].start == 0.40)
        #expect(words[0].end == 0.64)
        #expect(words[2].start == 1.04)
    }

    @Test func finalizeRemovesOverlapsAndZeroLengthWords() {
        let words = [
            TimedWord(text: "а", start: 1.0, end: 3.0),
            TimedWord(text: "б", start: 2.0, end: 2.0)
        ]
        let fixed = WordTimings.finalize(words)
        #expect(fixed[0].end == 2.0)
        #expect(fixed[1].end > fixed[1].start)
    }

    @Test func shiftedMovesWordsToChunkOffset() {
        let words = [TimedWord(text: "x", start: 0.5, end: 1.0)]
        let shifted = WordTimings.shifted(words, by: 25)
        #expect(shifted[0].start == 25.5)
        #expect(shifted[0].end == 26.0)
    }
}

// MARK: - Разрез длинного аудио

struct ChunkCutTests {
    @Test func cutsAtQuietestPointNearChunkEnd() {
        let rate = Int(AudioPCM.sampleRate)
        // 10 секунд громкого сигнала с паузой на 8.0–8.2 с
        var samples = (0..<(10 * rate)).map { i in Float(sin(Double(i) * 0.3)) * 0.8 }
        for i in (8 * rate)..<(Int(8.2 * Double(rate))) { samples[i] = 0 }
        let cut = TranscriptionPipeline.quietestCut(in: samples, searchSeconds: 4)
        let cutSeconds = Double(cut) / AudioPCM.sampleRate
        #expect(cutSeconds >= 8.0 && cutSeconds <= 8.2, "разрез должен попасть в паузу, получено \(cutSeconds) с")
    }

    @Test func keepsWholeChunkWhenTooShortToSearch() {
        let samples = [Float](repeating: 0.5, count: 100)
        #expect(TranscriptionPipeline.quietestCut(in: samples, searchSeconds: 4) == samples.count)
    }
}

// MARK: - Хранилище истории

struct HistoryStoreTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("golosok-history-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func persistsNotesAfterFlushAndReloads() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir, saveDelay: 10)
        let id = store.addNote(text: "Первая заметка")
        store.appendTextToNote(id: id, text: "Дополнение")
        store.flush()

        let reloaded = HistoryStore(directory: dir)
        #expect(reloaded.items.count == 1)
        #expect(reloaded.items.first?.text.contains("Дополнение") == true)
    }

    @Test func storesAudioAndTimingsAndDeletesThemWithNote() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir, saveDelay: 0)

        let source = TempFiles.makeURL(prefix: "test", ext: "wav")
        #expect(AudioPCM.writeWav(samples: [Float](repeating: 0, count: 1600), to: source))
        let id = store.addNote(text: "С аудио")
        store.storeAudio(for: id, from: source, move: true)
        store.storeTimings(for: id, words: [TimedWord(text: "С", start: 0, end: 0.1)], duration: 0.1)

        #expect(store.hasAudio(for: id))
        #expect(!FileManager.default.fileExists(atPath: source.path), "при move исходный файл переносится")
        #expect(store.timings(for: id)?.words.count == 1)

        store.deleteItem(at: 0)
        store.flush()
        #expect(!store.hasAudio(for: id))
        #expect(store.timings(for: id) == nil)
    }
}

// MARK: - Запуск процессов

struct ProcessRunnerTests {
    @Test func readsOutputLargerThanPipeBufferWithoutDeadlock() throws {
        // 1 МБ вывода — в 16 раз больше буфера канала, прежняя реализация зависала бы
        let result = try #require(ProcessRunner.run("/bin/sh", arguments: ["-c", "head -c 1048576 /dev/zero | tr '\\0' 'a'"], timeout: 20))
        #expect(result.succeeded)
        #expect(result.stdout.utf8.count == 1_048_576)
    }

    @Test func terminatesProcessOnTimeout() throws {
        let started = Date()
        let result = try #require(ProcessRunner.run("/bin/sleep", arguments: ["30"], timeout: 0.5))
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func passesStdinAndCapturesStderr() throws {
        let result = try #require(ProcessRunner.run("/bin/sh", arguments: ["-c", "cat; echo oops >&2"], stdin: Data("привет".utf8), timeout: 10))
        #expect(result.stdout == "привет")
        #expect(result.stderr.contains("oops"))
    }
}

// MARK: - Индикатор записи

struct RecordingMeterTests {
    @Test func pushesRealLevelsAsScrollingHistory() {
        let meter = RecordingMeter()
        meter.push(averagePowerDb: -5, elapsed: 65.4)
        #expect(meter.samples.count == RecordingMeter.barCount)
        #expect(meter.samples.last! > RecordingMeter.floorLevel)
        #expect(meter.samples.first == RecordingMeter.floorLevel)
        #expect(meter.elapsedText == "01:05")
        meter.reset()
        #expect(meter.samples.allSatisfy { $0 == RecordingMeter.floorLevel })
    }

    @Test func normalizesDecibelsIntoBarRange() {
        #expect(RecordingMeter.normalizedLevel(fromDecibels: -160) == RecordingMeter.floorLevel)
        #expect(RecordingMeter.normalizedLevel(fromDecibels: 0) == 1.0)
    }
}

// MARK: - Ответ локальной модели

struct LocalModelOutputTests {
    @Test func stripsEchoedTranscriptAndQuotes() {
        let raw = "<transcript>\nну короче завтра\n</transcript>\n«Завтра созвонимся.»"
        #expect(LocalSynthServiceClient.cleanModelOutput(raw) == "Завтра созвонимся.")
    }

    @Test func extractsCleanedSectionAfterHeader() {
        let raw = "Исходный текст: эм ну да\nОчищенный текст: Да."
        #expect(LocalSynthServiceClient.cleanModelOutput(raw) == "Да.")
    }

    @Test func returnsNilForEmptyOutput() {
        #expect(LocalSynthServiceClient.cleanModelOutput("  \n ") == nil)
    }
}

// MARK: - Сквозное распознавание GigaAM

struct GigaAMIntegrationTests {
    /// Синтезирует русскую речь системным голосом и распознаёт её встроенным движком.
    /// Пропускается, если в бандле нет модели или в системе нет русского голоса, например в CI.
    @Test(.enabled(if: ModelStore.shared.localModelPath(for: RecognitionModel.russianGigaAM.id) != nil, "нет модели gigaam.gguf"))
    func recognizesSynthesizedRussianSpeech() throws {
        let aiff = TempFiles.makeURL(prefix: "say", ext: "aiff")
        let wav = TempFiles.makeURL(prefix: "say", ext: "wav")
        defer { TempFiles.remove(aiff); TempFiles.remove(wav) }

        guard let say = ProcessRunner.run("/usr/bin/say", arguments: ["-v", "Milena", "-o", aiff.path, "Завтра в десять утра созвонимся с командой"], timeout: 30),
              say.succeeded else { return }

        #expect(AudioPCM.convertMediaToWav(aiff, output: wav))
        let reader = try #require(AudioChunkReader(url: wav))
        let samples = try #require(reader.samples(fromSecond: 0, length: reader.durationSeconds))

        let result = GigaAMEngine.shared.recognize(samples: samples)
        let text = result.text.lowercased()
        #expect(text.contains("завтра"), "распознано: \(result.text)")
        #expect(text.contains("команд"), "распознано: \(result.text)")
        #expect(!result.words.isEmpty)
        #expect(result.words.allSatisfy { $0.end >= $0.start })
    }
}
