import Foundation
import AVFoundation

/// Запись микрофона в WAV 16 кГц моно. Каждая запись идёт в собственный файл,
/// поэтому новая диктовка не затирает предыдущую, пока та ещё распознаётся.
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    struct Recording {
        let url: URL
        let duration: TimeInterval
    }

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private(set) var startedAt: Date?
    private var currentURL: URL?

    var isRecording: Bool { recorder?.isRecording == true }

    /// Начинает запись. `onMeter` вызывается на главном потоке ~20 раз в секунду.
    func start(onMeter: @escaping (_ powerDb: Float, _ elapsed: TimeInterval) -> Void) -> Bool {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: AudioPCM.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        let url = TempFiles.makeURL(prefix: "recording", ext: "wav")
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            // Рекордер мог заново создать файл с правами по умолчанию
            TempFiles.restrict(url)
            guard recorder.record() else {
                TempFiles.remove(url)
                return false
            }
            self.recorder = recorder
            self.currentURL = url
            let started = Date()
            self.startedAt = started

            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                let elapsed = Date().timeIntervalSince(started)
                onMeter(power, elapsed)
            }
            RunLoop.main.add(timer, forMode: .common)
            meterTimer = timer
            return true
        } catch {
            AppLogger.shared.error("Recording", "Не удалось начать запись", details: error.localizedDescription)
            TempFiles.remove(url)
            return false
        }
    }

    /// Останавливает запись и отдаёт файл; вызывающий отвечает за его удаление.
    func stop() -> Recording? {
        meterTimer?.invalidate()
        meterTimer = nil
        guard let recorder, let url = currentURL else { return nil }
        let duration = Date().timeIntervalSince(startedAt ?? Date())
        recorder.stop()
        self.recorder = nil
        self.currentURL = nil
        self.startedAt = nil
        return Recording(url: url, duration: duration)
    }

    /// Прерывает запись и удаляет файл.
    func cancel() {
        if let recording = stop() { TempFiles.remove(recording.url) }
    }
}
