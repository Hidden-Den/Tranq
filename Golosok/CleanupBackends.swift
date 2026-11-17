import Foundation

/// Локальная модель: llama-server с резервом на llama-cli.
struct LocalBackend: CleanupBackend {
    let modelPath: String

    func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        guard let result = await LocalSynthServiceClient.shared.synthesize(
            transcript: user, stylePrompt: system, modelPath: modelPath, timeout: timeout
        ) else { throw CleanupBackendError.unavailable }
        return result
    }
}

/// Внешний API: формат OpenAI или Anthropic, ответ принимается потоком.
struct ExternalBackend: CleanupBackend {
    let config: AIProviderConfig

    func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await stream(system: system, user: user) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                throw CleanupBackendError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CleanupBackendError.empty }
            return first
        }
    }

    private func stream(system: String, user: String) async throws -> String {
        let request = try ChatRequestBuilder.streamRequest(config: config, system: system, user: "<transcript>\(user)</transcript>")

        let started = CFAbsoluteTimeGetCurrent()
        var accumulated = ""
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw CleanupBackendError.unavailable }
            guard http.statusCode == 200 else { throw CleanupBackendError.http(http.statusCode) }

            var stripper = StreamingThinkTagStripper()
            var gotFirstToken = false
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if (json["type"] as? String) == "message_stop" { break }

                let chunk: String?
                if let choices = json["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any] {
                    chunk = delta["content"] as? String
                } else if let delta = json["delta"] as? [String: Any] {
                    chunk = delta["text"] as? String
                } else {
                    chunk = nil
                }
                guard let piece = chunk, !piece.isEmpty else { continue }
                if !gotFirstToken {
                    gotFirstToken = true
                    AppLogger.shared.info("Synthesizer", String(format: "Первый токен получен за %.2f с", CFAbsoluteTimeGetCurrent() - started))
                }
                if let clean = stripper.feed(piece) { accumulated.append(clean) }
            }
            if let rest = stripper.finish() { accumulated.append(rest) }
        } catch let error as CleanupBackendError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw CleanupBackendError.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CleanupBackendError.unavailable
        }

        let text = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CleanupBackendError.empty }
        return text
    }
}
