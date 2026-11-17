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
