import Foundation
import AVFoundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Кастомная акустическая айдентика
struct SoundEffect {
    static func playStart() { LuxurySoundSynth.shared.playStart() }
    static func playSuccess() { LuxurySoundSynth.shared.playSuccess() }
    static func playCancel() { LuxurySoundSynth.shared.playCancel() }
    static func playCopy() { LuxurySoundSynth.shared.playCopy() }
    static func playDelete() { LuxurySoundSynth.shared.playDelete() }
    static func playWarning() { LuxurySoundSynth.shared.playWarning() }
}

/// Координатор диктовки: запись, импорт файлов, запуск конвейера и вставка результата.
///
/// Публикует только редко меняющееся состояние для HUD. Индикатор громкости живёт в
/// `RecordingMeter`, история — в `HistoryStore`, воспроизведение — в `PlaybackController`.
/// Все методы вызываются с главного потока.
final class AudioCapture: ObservableObject {
    static let shared = AudioCapture()

    @Published var isRecording = false
    @Published var isProcessingFile = false
    @Published var isSynthesizingThought = false
    @Published var hudStatusMessage: String?
    @Published var fileProcessingProgress: Double = 0.0
    @Published var transcribedText = ""
    @Published var warningMessage: String?
    @Published var isSuccessDone = false
    /// Подпись необычного режима для окошка записи: «Промпт» или имя правила. Пусто при обычной очистке.
    @Published var modeLabel = ""

    private let contextCapture = DictationContextCapture()
    private let recorder = AudioRecorder()
    private let pipeline = TranscriptionPipeline.shared
    private let history = HistoryStore.shared
    private let preferences = AppPreferences.shared
    private var escMonitor: Any?

    private init() {
        TempFiles.purgeStale()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            UpdateService.shared.checkUpdates()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [history] in
            DashboardStatsStore.shared.refresh(history: history.items)
        }
    }

    // MARK: - Запись

    /// `promptRequested` действует только при начале записи; остановка от него не зависит.
    func toggleRecording(promptRequested: Bool = false) {
        if isProcessingFile {
            SoundEffect.playCancel()
            return
        }
        if isRecording { stopRecording() } else { startRecording(promptRequested: promptRequested) }
    }

    /// `promptRequested` включает режим промпта на одну диктовку, если он разрешён в настройках.
    func startRecording(promptRequested: Bool = false) {
        guard !isProcessingFile, !isRecording else { return }
        isSynthesizingThought = false
        hudStatusMessage = nil

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted { DispatchQueue.main.async { self.startRecording(promptRequested: promptRequested) } }
            }
            return
        case .denied, .restricted:
            transcribedText = String(localized: "Нет доступа к микрофону.")
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        let meter = RecordingMeter.shared
        meter.reset()
        guard recorder.start(onMeter: { power, elapsed in
            meter.push(averagePowerDb: power, elapsed: elapsed)
            OverlayPanelManager.shared.keepFront()
        }) else { return }

        beginDictationContext(promptRequested: promptRequested)
        SoundEffect.playStart()
        AppLogger.shared.info("Recording", "Запись началась", details: "режим: \(HotKeySettings.shared.mode == .pushToTalk ? "рация" : "переключатель")")
        // Пока человек говорит, заранее поднимаем модели, чтобы распознавание и синтез стартовали без загрузки
        SpeechRecognizerFactory.current()?.prewarm()
        if VoiceIntelligenceSettings.shared.mode == .smart {
            ThoughtSynthesizer.shared.prewarmConnection(for: VoiceIntelligenceSettings.shared.engine)
        }

        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { DispatchQueue.main.async { self?.cancelRecording() } }
        }

        warningMessage = nil
        isRecording = true
        transcribedText = String(localized: "Запись идет...")
        OverlayPanelManager.shared.showOverlay()
    }

    func stopRecording() {
        guard isRecording else { return }
        removeEscMonitor()
        let focusTarget = InsertionService.shared.captureFocus()
        // Контекст фиксируется сразу: новая запись сразу после этой не должна его подменить
        let frozenContext = contextCapture.freeze()
        hudStatusMessage = nil
        modeLabel = ""

        guard let recording = recorder.stop() else {
            isRecording = false
            return
        }
        AppLogger.shared.info(
            "Recording",
            "Запись остановлена",
            details: String(format: "длительность %.1f с, цель вставки: %@", recording.duration, focusTarget?.appName ?? "?")
        )

        isRecording = false
        fileProcessingProgress = 0.0
        RecordingMeter.shared.reset()
        transcribedText = String(localized: "Расшифровка...")

        Task { @MainActor [weak self] in
            guard let self else {
                TempFiles.remove(recording.url)
                return
            }
            let resolved = self.resolveLevel(for: await frozenContext.resolve())
            if let rule = resolved.ruleName {
                AppLogger.shared.info("Rules", "Правило: \(rule)")
            }
            let job = TranscriptionPipeline.Job(
                source: .recording(recording.url, duration: recording.duration),
                focusTarget: focusTarget,
                level: resolved.level
            )
            self.pipeline.run(job, onStageTwoStarted: { [weak self] in
                self?.isSynthesizingThought = true
            }, progress: { _ in }) { [weak self] result in
                guard let self else { return }
                self.isSynthesizingThought = false
                self.handle(result, job: job) {
                    OverlayPanelManager.shared.scheduleHide(after: 1.0)
                }
                TempFiles.remove(recording.url)
            }
        }
    }

    // MARK: - Контекст диктовки

    private func resolveLevel(for context: DictationContext) -> ResolvedLevel {
        let settings = VoiceIntelligenceSettings.shared
        return CleanupLevelResolver.resolve(
            context,
            rules: DictationRuleStore.shared.rules,
            mode: settings.mode,
            promptModeEnabled: settings.promptModeEnabled
        )
    }

    /// Снимает контекст при начале записи. Подпись режима сначала по приложению, потом уточняется по сайту.
    private func beginDictationContext(promptRequested: Bool) {
        let app = NSWorkspace.shared.frontmostApplication.map { (pid: $0.processIdentifier, bundleId: $0.bundleIdentifier) }
        modeLabel = resolveLevel(for: DictationContext(bundleId: app?.bundleId, host: nil, promptRequested: promptRequested)).overlayLabel ?? ""
        contextCapture.begin(app: app, promptRequested: promptRequested) { [weak self] host in
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
                let context = DictationContext(bundleId: app?.bundleId, host: host, promptRequested: promptRequested)
                self.modeLabel = self.resolveLevel(for: context).overlayLabel ?? ""
            }
        }
    }

    func cancelRecording() {
        removeEscMonitor()
        guard isRecording else { return }
        recorder.cancel()
        SoundEffect.playCancel()
        warningMessage = nil
        isRecording = false
        isSynthesizingThought = false
        hudStatusMessage = nil
        modeLabel = ""
        RecordingMeter.shared.reset()
        transcribedText = String(localized: "Запись отменена")
        OverlayPanelManager.shared.hideOverlay()
    }

    private func removeEscMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    // MARK: - Импорт файлов

    func importAndTranscribeFile() {
        if isRecording || isProcessingFile {
            SoundEffect.playCancel()
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let webmType = UTType(filenameExtension: "webm") ?? .movie
        let mkvType = UTType(filenameExtension: "mkv") ?? .movie
        let oggType = UTType(filenameExtension: "ogg") ?? .audio
        panel.allowedContentTypes = [.audio, .movie, .mp3, .mpeg4Audio, .wav, webmType, mkvType, oggType]
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            importFiles(panel.urls)
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !isRecording, !isProcessingFile else {
            SoundEffect.playCancel()
            return
        }
        let media = urls.filter { Self.isMediaURL($0) }
        guard !media.isEmpty else { return }
        processNextFile(media, index: 0)
    }

    private func processNextFile(_ urls: [URL], index: Int) {
        guard index < urls.count else {
            isProcessingFile = false
            OverlayPanelManager.shared.scheduleHide(after: 0.8)
            return
        }
        warningMessage = nil
        isProcessingFile = true
        fileProcessingProgress = 0.0
        transcribedText = String(localized: "Извлечение аудио...")
        OverlayPanelManager.shared.showOverlay()

        let job = TranscriptionPipeline.Job(source: .mediaFile(urls[index]), focusTarget: nil, level: nil)
        pipeline.run(job, progress: { [weak self] fraction in
            self?.fileProcessingProgress = fraction
            OverlayPanelManager.shared.keepFront()
        }) { [weak self] result in
            guard let self else { return }
            self.handle(result, job: job) {
                self.processNextFile(urls, index: index + 1)
            }
        }
    }

    private static func isMediaURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let mediaExts: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "aac", "flac", "ogg", "opus", "mp4", "mov", "m4v", "webm", "mkv", "avi"]
        if mediaExts.contains(ext) { return true }
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]), let ut = values.contentType {
            return ut.conforms(to: .audio) || ut.conforms(to: .movie)
        }
        return false
    }

    // MARK: - Результат

    private func handle(
        _ result: Result<TranscriptionPipeline.Output, TranscriptionPipeline.Failure>,
        job: TranscriptionPipeline.Job,
        then next: @escaping () -> Void
    ) {
        switch result {
        case .failure(let failure):
            let message: String
            switch failure {
            case .noRecognizer, .nothingRecognized:
                if case .nothingRecognized(let seconds) = failure {
                    AppLogger.shared.warn("Recognition", "Речь не распознана", details: String(format: "аудио %.1f с", seconds))
                }
                message = String(localized: "Речь не распознана")
            case .audioUnreadable:
                message = job.source.isFileImport ? String(localized: "Не удалось извлечь аудио") : String(localized: "Ошибка чтения файла")
            }
            OverlayPanelManager.shared.showWarning(message: message)
            if job.source.isFileImport { next() }
        case .success(let output):
            save(output)
            insert(output, isFileImport: job.source.isFileImport, target: job.focusTarget, then: next)
        }
    }

    private func save(_ output: TranscriptionPipeline.Output) {
        let durationText: String
        if output.audioSeconds >= 60.0 {
            durationText = String(format: String(localized: "%.0f мин"), output.audioSeconds / 60.0)
        } else {
            durationText = String(format: String(localized: "%.0f сек"), output.audioSeconds.rounded())
        }
        let item = TranscriptionItem(
            id: output.noteId,
            date: TranscriptionItem.formattedNow(),
            text: output.finalText,
            duration: durationText,
            speedup: output.speedup,
            isUnread: true
        )
        history.storeAudio(for: item.id, from: output.audioURL, move: output.ownsAudioFile)
        // Тайминги слов храним только для текста без ИИ: модель переставляет и убирает слова
        if !output.isTransformedByAI && !output.words.isEmpty {
            history.storeTimings(for: item.id, words: output.words, duration: output.audioSeconds)
        }
        history.insert(item)
        NotificationCenter.default.post(name: NSNotification.Name("AutoSelectNote"), object: item.id)
    }

    private func insert(_ output: TranscriptionPipeline.Output, isFileImport: Bool, target: FocusSnapshot?, then next: @escaping () -> Void) {
        transcribedText = output.finalText
        isSuccessDone = true
        let fallbackNotice = isFileImport ? nil : FallbackNotice.message(
            for: output.fallback,
            providerID: AIProviderStore.shared.providerID,
            engine: VoiceIntelligenceSettings.shared.engine
        )

        if isFileImport || !preferences.autoPasteEnabled {
            InsertionService.shared.copyToPasteboard(text: output.finalText, markTransient: false)
            hudStatusMessage = fallbackNotice
            SoundEffect.playSuccess()
            next()
            return
        }
        InsertionService.shared.paste(text: output.finalText, target: target, autoPasteEnabled: true) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .pasted:
                    self?.hudStatusMessage = fallbackNotice
                case .copied, .focusChanged:
                    self?.hudStatusMessage = String(localized: "Скопировано")
                case .secureInput:
                    self?.hudStatusMessage = String(localized: "Защищенный ввод")
                case .accessibilityDenied:
                    self?.hudStatusMessage = String(localized: "Нет прав")
                }
                SoundEffect.playSuccess()
                next()
            }
        }
    }
}
