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
    /// Целые секунды записи. Оверлей показывает их как «7 с», без минут.
    @Published private(set) var elapsedSeconds: Int = 0

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
            elapsedSeconds = second
        }
    }

    func reset() {
        samples = Array(repeating: Self.floorLevel, count: Self.barCount)
        elapsedSeconds = 0
        lastElapsedSecond = -1
    }

    static func normalizedLevel(fromDecibels power: Float) -> Float {
        max(floorLevel, min(1.0, (power + 40.0) / 35.0))
    }
}
