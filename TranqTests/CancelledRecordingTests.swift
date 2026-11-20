import Testing
import Foundation
@testable import Tranq

/// Esc ловится глобально: нажатый в чужом окне посреди диктовки, он отменял запись и стирал речь.
/// Так 20.11.2026 пропало 25 и 40 секунд: Esc прервал Claude, следующее Fn начало новую запись.
struct CancelledRecordingTests {
    @Test func longCancelledRecordingKeepsSpeech() {
        #expect(CancelledRecording.keepsSpeech(duration: 25))
        #expect(CancelledRecording.keepsSpeech(duration: 40))
    }

    @Test func accidentalStartIsDiscarded() {
        #expect(!CancelledRecording.keepsSpeech(duration: 0.4))
        #expect(!CancelledRecording.keepsSpeech(duration: 2.9))
    }

    @Test func thresholdIsThreeSeconds() {
        #expect(CancelledRecording.minimumKeptSeconds == 3)
        #expect(CancelledRecording.keepsSpeech(duration: 3))
    }

    /// Отмена всегда видна в журнале: раньше она не оставляла строки, и потерю нельзя было найти.
    @Test func logDetailsNameDurationAndOutcome() {
        #expect(CancelledRecording.logDetails(duration: 25.04) == "длительность 25.0 с, речь сохранена в историю")
        #expect(CancelledRecording.logDetails(duration: 1.26) == "длительность 1.3 с, речь удалена")
    }
}
