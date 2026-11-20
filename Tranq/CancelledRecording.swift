import Foundation

/// Что делать с речью, когда запись отменена клавишей Esc.
///
/// Esc ловится глобально, поэтому Esc, нажатый в чужом окне посреди диктовки, неотличим от отмены.
/// Короткая запись — скорее случайный старт, её речь удаляется. Длинная распознаётся и попадает
/// в историю без вставки в поле: человек не теряет сказанное.
enum CancelledRecording {
    static let minimumKeptSeconds: TimeInterval = 3

    static func keepsSpeech(duration: TimeInterval) -> Bool {
        duration >= minimumKeptSeconds
    }

    static func logDetails(duration: TimeInterval) -> String {
        let outcome = keepsSpeech(duration: duration) ? "речь сохранена в историю" : "речь удалена"
        return String(format: "длительность %.1f с, ", duration) + outcome
    }
}
