import Foundation
import AVFoundation

/// Воспроизведение аудио заметки.
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

    init(history: HistoryStore) {
        self.history = history
    }

    func hasAudio(for id: UUID) -> Bool {
        history.hasAudio(for: id)
    }

    /// Читает длительность аудио в фоне, чтобы строка плеера сразу показала время.
    func prepare(for id: UUID) {
        guard durations[id] == nil, history.hasAudio(for: id) else { return }
        let url = history.audioURL(for: id)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
            let duration = player.duration
            DispatchQueue.main.async { self?.durations[id] = duration }
        }
    }

    func toggleSyncedPlayback(for id: UUID) {
        guard history.hasAudio(for: id) else { return }
        if playingItemId == id, let player = audioPlayer {
            if player.isPlaying {
                player.pause(); stopPlaybackTimer(); isPlayerPlaying = false
            } else {
                player.play(); startPlaybackTimer(for: id); isPlayerPlaying = true
            }
            return
        }
        audioPlayer?.stop()
        guard let player = try? AVAudioPlayer(contentsOf: history.audioURL(for: id)) else { return }
        audioPlayer = player
        durations[id] = player.duration
        player.play()
        playingItemId = id
        playheadTime = 0
        isPlayerPlaying = true
        startPlaybackTimer(for: id)
    }

    /// Перемотка; если заметка ещё не играла, запускает её с нужного места.
    func seekSynced(to time: Double, for id: UUID) {
        if playingItemId != id { toggleSyncedPlayback(for: id) }
        guard playingItemId == id, let player = audioPlayer else { return }
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
        playingItemId = nil
        playheadTime = 0
        isPlayerPlaying = false
        stopPlaybackTimer()
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
