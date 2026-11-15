import Foundation

/// Потоковый фильтр тегов размышлений (<think>...</think>)
public struct StreamingThinkTagStripper {
    private enum State {
        case outside
        case insideThink
    }

    private var state: State = .outside
    private var buffer = ""

    public init() {}

    /// Принимает очередной входящий чанк токенов и возвращает очищенный текст, готовый к отображению/вставке
    public mutating func feed(_ chunk: String) -> String? {
        buffer.append(chunk)
        var output = ""

        while !buffer.isEmpty {
            switch state {
            case .outside:
                if let openRange = buffer.range(of: "<think>") {
                    let before = String(buffer[..<openRange.lowerBound])
                    output.append(before)
                    buffer.removeSubrange(..<openRange.upperBound)
                    state = .insideThink
                } else if buffer.contains("<") {
                    if let ltIndex = buffer.lastIndex(of: "<") {
                        let potentialTag = String(buffer[ltIndex...])
                        if "<think>".hasPrefix(potentialTag) {
                            let before = String(buffer[..<ltIndex])
                            output.append(before)
                            buffer = potentialTag
                            return output.isEmpty ? nil : output
                        } else {
                            output.append(buffer)
                            buffer = ""
                        }
                    }
                } else {
                    output.append(buffer)
                    buffer = ""
                }

            case .insideThink:
                if let closeRange = buffer.range(of: "</think>") {
                    buffer.removeSubrange(..<closeRange.upperBound)
                    state = .outside
                } else {
                    if let ltIndex = buffer.lastIndex(of: "<") {
                        let potentialClose = String(buffer[ltIndex...])
                        if "</think>".hasPrefix(potentialClose) {
                            buffer = potentialClose
                            return output.isEmpty ? nil : output
                        }
                    }
                    buffer = ""
                    return output.isEmpty ? nil : output
                }
            }
        }

        return output.isEmpty ? nil : output
    }

    /// Завершение стрима, сброс оставшегося буфера
    public mutating func finish() -> String? {
        defer { buffer = "" }
        if state == .outside {
            return buffer.isEmpty ? nil : buffer
        } else {
            // Незакрытый тег <think> в конце ответа отсекается полностью
            return nil
        }
    }
}
