import Foundation
import Combine

/// Живой индикатор записи для оверлея.
///
/// Вынесен из `AudioCapture`, чтобы обновления 20 раз в секунду перерисовывали
/// только оверлей, а не главное окно, настройки и меню, подписанные на `AudioCapture`.
/// Используется только с главного потока.
final class RecordingMeter: ObservableObject {
    static let shared = RecordingMeter()

    static let barCount = 18
    static let floorLevel: Float = 0.15

    @Published private(set) var samples: [Float] = Array(repeating: RecordingMeter.floorLevel, count: RecordingMeter.barCount)
    @Published private(set) var elapsedText: String = "00:00"

    private var lastElapsedSecond = -1

    /// Принимает среднюю мощность сигнала в дБ и время записи.
    /// Полосы — скользящая история реального уровня: новая точка справа, старые сдвигаются влево.
    func push(averagePowerDb power: Float, elapsed: TimeInterval) {
        let level = Self.normalizedLevel(fromDecibels: power)
        let previous = samples.last ?? Self.floorLevel
        var next = Array(samples.dropFirst())
        next.append(previous * 0.35 + level * 0.65)
        samples = next

        let second = Int(elapsed)
        if second != lastElapsedSecond {
            lastElapsedSecond = second
            elapsedText = String(format: "%02d:%02d", second / 60, second % 60)
        }
    }

    func reset() {
        samples = Array(repeating: Self.floorLevel, count: Self.barCount)
        elapsedText = "00:00"
        lastElapsedSecond = -1
    }

    static func normalizedLevel(fromDecibels power: Float) -> Float {
        max(floorLevel, min(1.0, (power + 40.0) / 35.0))
    }
}
