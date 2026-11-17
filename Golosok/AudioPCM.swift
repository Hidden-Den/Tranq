import Foundation
import AVFoundation

/// Уникальные временные файлы приложения.
///
/// Раньше пути были фиксированными (`temp_chunk_0.wav` и т. п.), и две диктовки
/// подряд могли перезаписать файлы друг друга, пока первая ещё распознавалась.
enum TempFiles {
    static let directory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Golosok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func makeURL(prefix: String, ext: String) -> URL {
        directory.appendingPathComponent("\(prefix)-\(UUID().uuidString).\(ext)")
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Удаляет остатки прошлых запусков, например после аварийного завершения.
    static func purgeStale(olderThan age: TimeInterval = 24 * 3600) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for url in items {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }
}

/// Чтение, запись и конвертация звука в моно PCM float32 16 кГц — формат всех движков.
enum AudioPCM {
    static let sampleRate: Double = 16_000

    static var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// Читает весь файл как моно float32 16 кГц, пересэмплируя при необходимости.
    static func loadSamples(from url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let source = file.processingFormat
        if source.sampleRate == sampleRate, source.channelCount == 1, source.commonFormat == .pcmFormatFloat32 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
            do { try file.read(into: buffer) } catch { return nil }
            guard let channel = buffer.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return convertFile(file)
    }

    private static func convertFile(_ file: AVAudioFile) -> [Float]? {
        let target = targetFormat
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return nil }
        let inputCapacity: AVAudioFrameCount = 8192
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inputCapacity) else { return nil }
        let ratio = sampleRate / file.processingFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputCapacity) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else { return nil }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * ratio) + 1)
        var reachedEnd = false
        var readError = false

        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if reachedEnd { outStatus.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: inputBuffer, frameCount: inputCapacity)
                } catch {
                    readError = true
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            }
            if status == .error || conversionError != nil || readError { return samples.isEmpty ? nil : samples }
            if let channel = outputBuffer.floatChannelData?[0], outputBuffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
            }
            if status == .endOfStream || (reachedEnd && outputBuffer.frameLength == 0) { break }
        }
        return samples
    }

    @discardableResult
    static func writeWav(samples: [Float], to url: URL) -> Bool {
        let format = targetFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))),
              let channel = buffer.floatChannelData?[0] else { return false }
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel.update(from: base, count: src.count) }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        do {
            try? FileManager.default.removeItem(at: url)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Импорт медиафайлов

    /// Извлекает звуковую дорожку из аудио или видео во временный WAV, моно float32 16 кГц.
    /// Порядок: AVFoundation, затем ffmpeg для форматов вроде WebM и MKV, затем AVAudioConverter.
    /// Файл пишется потоково, поэтому длинные записи не занимают память целиком.
    static func convertMediaToWav(_ inputURL: URL, output outputURL: URL) -> Bool {
        if convertWithAssetReader(inputURL, output: outputURL) { return true }
        if convertWithFFmpeg(inputURL: inputURL, outputURL: outputURL) { return true }
        guard let file = try? AVAudioFile(forReading: inputURL),
              let samples = convertFile(file), !samples.isEmpty else { return false }
        return writeWav(samples: samples, to: outputURL)
    }

    private static func convertWithAssetReader(_ url: URL, output outputURL: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        var audioTrack: AVAssetTrack?
        Task.detached {
            audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
            semaphore.signal()
        }
        semaphore.wait()
        guard let track = audioTrack, let reader = try? AVAssetReader(asset: asset) else { return false }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(trackOutput)
        try? FileManager.default.removeItem(at: outputURL)
        guard let outputFile = try? AVAudioFile(forWriting: outputURL, settings: targetFormat.settings),
              reader.startReading() else { return false }

        var writeFailed = false
        while reader.status == .reading && !writeFailed {
            autoreleasepool {
                guard let sampleBuffer = trackOutput.copyNextSampleBuffer(),
                      let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
                let byteCount = CMBlockBufferGetDataLength(blockBuffer)
                let frameCount = AVAudioFrameCount(byteCount / MemoryLayout<Float>.size)
                guard frameCount > 0,
                      let pcm = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount),
                      let channel = pcm.floatChannelData?[0] else { return }
                // Блок может состоять из нескольких несмежных сегментов памяти, поэтому
                // копируем через CMBlockBufferCopyDataBytes, а не по указателю на первый сегмент.
                let status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: Int(frameCount) * MemoryLayout<Float>.size, destination: channel)
                guard status == kCMBlockBufferNoErr else { return }
                pcm.frameLength = frameCount
                do { try outputFile.write(from: pcm) } catch { writeFailed = true }
            }
        }
        return reader.status == .completed && !writeFailed && outputFile.length > 0
    }

    private static func convertWithFFmpeg(inputURL: URL, outputURL: URL) -> Bool {
        var candidates: [String] = []
        if let bundled = Bundle.main.path(forResource: "ffmpeg", ofType: nil) { candidates.append(bundled) }
        candidates.append(contentsOf: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"])
        guard let ffmpegPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            AppLogger.shared.warn("Import", "ffmpeg не найден, ни встроенный, ни системный", details: inputURL.lastPathComponent)
            return false
        }
        guard let result = ProcessRunner.run(
            ffmpegPath,
            arguments: ["-nostdin", "-i", inputURL.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_f32le", outputURL.path, "-y"],
            timeout: 30 * 60
        ) else { return false }
        let ok = result.succeeded && FileManager.default.fileExists(atPath: outputURL.path)
        if ok {
            AppLogger.shared.info("Import", "Конвертация аудио через ffmpeg выполнена")
        } else {
            AppLogger.shared.warn("Import", "ffmpeg не смог конвертировать файл", details: "\(inputURL.lastPathComponent), код \(result.status)")
        }
        return ok
    }
}

/// Последовательное чтение WAV-файла фрагментами заданной длины.
final class AudioChunkReader {
    private let file: AVAudioFile
    private let converterNeeded: Bool
    let totalFrames: AVAudioFramePosition
    let sampleRate: Double

    var durationSeconds: Double { Double(totalFrames) / sampleRate }

    init?(url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        self.file = file
        self.totalFrames = file.length
        self.sampleRate = file.processingFormat.sampleRate
        self.converterNeeded = file.processingFormat.sampleRate != AudioPCM.sampleRate || file.processingFormat.channelCount != 1
        guard !converterNeeded else { return nil }
    }

    /// Фрагмент `[start, start + length)` в секундах; nil при ошибке чтения.
    func samples(fromSecond start: Double, length: Double) -> [Float]? {
        let startFrame = AVAudioFramePosition(start * sampleRate)
        guard startFrame < totalFrames else { return [] }
        let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(length * sampleRate), totalFrames - startFrame))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else { return [] }
        file.framePosition = startFrame
        do { try file.read(into: buffer, frameCount: frameCount) } catch { return nil }
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
