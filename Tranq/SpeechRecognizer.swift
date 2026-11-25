import Foundation

struct RecognitionResult {
    let text: String
    let words: [TimedWord]

    static let empty = RecognitionResult(text: "", words: [])
}

/// Движок распознавания речи. Принимает моно PCM float32 16 кГц.
protocol SpeechRecognizer: AnyObject {
    var displayName: String { get }
    /// Максимальная длина одного фрагмента, которую движок принимает за раз.
    var maxChunkSeconds: Double { get }
    /// Загрузка модели заранее, например в начале записи.
    func prewarm()
    /// Синхронное распознавание; вызывается с фоновой очереди конвейера.
    func recognize(samples: [Float]) -> RecognitionResult
}

/// Выбор движка под активную модель из `ModelStore`.
enum SpeechRecognizerFactory {
    static func current() -> SpeechRecognizer? {
        let store = ModelStore.shared
        guard let model = store.model(named: store.activeModelID) else { return nil }
        if let engine = TranscribeEngine.engine(for: model) {
            return engine
        }
        return WhisperCLIEngine(model: model)
    }
}
