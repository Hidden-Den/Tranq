import Foundation
import AVFoundation

/// Воспроизведение аудио заметки с синхронной подсветкой слов.
final class PlaybackController: ObservableObject {
    static let shared = PlaybackController(history: .shared)

    @Published private(set) var playingItemId: UUID?
    @Published private(set) var playheadTime: Double = 0
    @Published private(set) var isPlayerPlaying = false

    private let history: HistoryStore
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var preloadedPlayerId: UUID?

    init(history: HistoryStore) {
        self.history = history
    }

    /// Тайминги заметки; заодно заранее готовит плеер, чтобы старт был мгновенным.
    func timings(for id: UUID) -> (words: [TimedWord], duration: Double)? {
        guard let result = history.timings(for: id) else { return nil }
        preloadAudio(for: id)
        return result
    }

    func hasAudioFile(for item: TranscriptionItem) -> Bool {
        history.hasAudio(for: item.id)
    }

    func toggleSyncedPlayback(for id: UUID) {
        guard history.hasAudio(for: id) else { return }
        if playingItemId == id {
            if audioPlayer?.isPlaying == true {
                audioPlayer?.pause(); stopPlaybackTimer(); isPlayerPlaying = false
            } else if let player = audioPlayer {
                player.play(); startPlaybackTimer(for: id); isPlayerPlaying = true
            }
            return
        }
        audioPlayer?.stop()
        if preloadedPlayerId != id {
            do { audioPlayer = try AVAudioPlayer(contentsOf: history.audioURL(for: id)) } catch { return }
        }
        preloadedPlayerId = nil
        audioPlayer?.play()
        playingItemId = id
        playheadTime = 0
        isPlayerPlaying = true
        startPlaybackTimer(for: id)
    }

    func seekSynced(to time: Double, for id: UUID) {
        guard let player = audioPlayer else { return }
        player.currentTime = min(max(time, 0), player.duration)
        if playingItemId == id {
            if !player.isPlaying {
                player.play()
                startPlaybackTimer(for: id)
                isPlayerPlaying = true
            }
            playheadTime = time
        }
    }

    func stopSyncedPlayback() {
        audioPlayer?.stop()
        playingItemId = nil
        preloadedPlayerId = nil
        playheadTime = 0
        isPlayerPlaying = false
        stopPlaybackTimer()
    }

    func toggleAudioPlayback(for item: TranscriptionItem) {
        if playingItemId == item.id {
            audioPlayer?.stop(); playingItemId = nil; isPlayerPlaying = false
            return
        }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: history.audioURL(for: item.id))
            audioPlayer?.play()
            playingItemId = item.id
            isPlayerPlaying = true
        } catch {}
    }

    private func preloadAudio(for id: UUID) {
        guard preloadedPlayerId != id else { return }
        preloadedPlayerId = id
        let url = history.audioURL(for: id)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
            DispatchQueue.main.async {
                guard let self, self.preloadedPlayerId == id, self.playingItemId == nil else { return }
                self.audioPlayer = player
            }
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
