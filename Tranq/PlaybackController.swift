import Foundation
import AVFoundation
import Combine

/// Воспроизведение аудио заметки из памяти: `AVAudioPlayer(data:)`, открытых временных файлов нет.
/// Байты приходят из `HistoryStore.loadAudio` в фоне, главный поток расшифровки не ждёт.
/// Подписка на `lockState`: при запирании плеер останавливается и отпускает расшифрованное.
final class PlaybackController: ObservableObject {
    static let shared = PlaybackController(history: .shared)

    @Published private(set) var playingItemId: UUID?
    @Published private(set) var playheadTime: Double = 0
    @Published private(set) var isPlayerPlaying = false
    /// Длительность аудио заметок, которые уже открывали.
    @Published private(set) var durations: [UUID: Double] = [:]

    private let history: HistoryStore
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    /// Заметка, чьё аудио сейчас читается, и место, с которого начать.
    private var loadingId: UUID?
    private var loadingStart: Double = 0
    private var lockObserver: AnyCancellable?

    init(history: HistoryStore) {
        self.history = history
        lockObserver = history.$lockState.sink { [weak self] state in
            if state == .locked || state == .keyUnavailable { self?.release() }
        }
    }

    /// Держит ли плеер расшифрованные байты.
    var isAudioLoaded: Bool { audioPlayer != nil }

    func hasAudio(for id: UUID) -> Bool {
        history.hasAudio(for: id)
    }

    /// Читает длительность аудио в фоне, чтобы строка плеера сразу показала время.
    func prepare(for id: UUID) {
        guard durations[id] == nil, history.hasAudio(for: id) else { return }
        history.loadAudio(for: id) { [weak self] result in
            guard case .success(let data?) = result, let player = try? AVAudioPlayer(data: data) else { return }
            self?.durations[id] = player.duration
        }
    }

    func toggleSyncedPlayback(for id: UUID) {
        if playingItemId == id, let player = audioPlayer {
            if player.isPlaying {
                player.pause(); stopPlaybackTimer(); isPlayerPlaying = false
            } else {
                player.play(); startPlaybackTimer(for: id); isPlayerPlaying = true
            }
            return
        }
        startPlayback(for: id, at: 0)
    }

    /// Перемотка; если заметка ещё не играла, запускает её с нужного места.
    func seekSynced(to time: Double, for id: UUID) {
        guard playingItemId == id, let player = audioPlayer else {
            startPlayback(for: id, at: time)
            return
        }
        player.currentTime = min(max(time, 0), player.duration)
        if !player.isPlaying {
            player.play()
            startPlaybackTimer(for: id)
            isPlayerPlaying = true
        }
        playheadTime = player.currentTime
    }

    func stopSyncedPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        loadingId = nil
        playingItemId = nil
        playheadTime = 0
        isPlayerPlaying = false
        stopPlaybackTimer()
    }

    /// Останавливает плеер и отпускает расшифрованные байты. Зовётся при запирании истории.
    func release() {
        stopSyncedPlayback()
        durations.removeAll()
    }

    /// Читает аудио в фоне и запускает его с `time`. Повторный вызов во время чтения меняет только место.
    private func startPlayback(for id: UUID, at time: Double) {
        if loadingId == id {
            loadingStart = time
            return
        }
        guard history.hasAudio(for: id) else { return }
        stopSyncedPlayback()
        loadingId = id
        loadingStart = time
        history.loadAudio(for: id) { [weak self] result in
            guard let self, self.loadingId == id else { return }
            self.loadingId = nil
            let data: Data
            switch result {
            case .success(let loaded?): data = loaded
            case .success(nil), .failure(HistoryAudioError.locked): return
            case .failure(let error):
                AppLogger.shared.error("Playback", "Аудио заметки не прочитано", details: "\(id.uuidString): \(error)")
                return
            }
            guard let player = try? AVAudioPlayer(data: data) else { return }
            self.audioPlayer = player
            self.durations[id] = player.duration
            player.currentTime = min(max(self.loadingStart, 0), player.duration)
            player.play()
            self.playingItemId = id
            self.playheadTime = player.currentTime
            self.isPlayerPlaying = true
            self.startPlaybackTimer(for: id)
        }
    }

    private func startPlaybackTimer(for id: UUID) {
        stopPlaybackTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.audioPlayer else {
                self?.stopPlaybackTimer()
                return
            }
            guard self.playingItemId == id else { self.stopPlaybackTimer(); return }
            if player.isPlaying {
                self.playheadTime = player.currentTime
            } else if player.duration > 0 && player.currentTime >= player.duration - 0.05 {
                self.stopSyncedPlayback()
            } else {
                self.stopPlaybackTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
}
