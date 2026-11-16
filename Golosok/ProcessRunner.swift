import Foundation

/// Запуск внешних CLI без риска взаимной блокировки.
///
/// stdout и stderr читаются параллельно с работой процесса, поэтому вывод больше
/// ёмкости канала (~64 КБ) не подвешивает ни процесс, ни приложение.
/// По истечении таймаута процесс завершается.
enum ProcessRunner {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool

        var succeeded: Bool { status == 0 && !timedOut }
    }

    static func run(
        _ executable: String,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval? = nil
    ) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = stdin.map { _ in Pipe() }
        if let inPipe { process.standardInput = inPipe } else { process.standardInput = FileHandle.nullDevice }

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let readQueue = DispatchQueue(label: "golosok.process-runner.read", attributes: .concurrent)

        do {
            try process.run()
        } catch {
            AppLogger.shared.error("Process", "Не удалось запустить \(URL(fileURLWithPath: executable).lastPathComponent)", details: error.localizedDescription)
            return nil
        }

        group.enter()
        readQueue.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        readQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if let stdin, let inPipe {
            readQueue.async {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        var timedOut = false
        if let timeout {
            let deadline = DispatchTime.now() + timeout
            let exited = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                exited.signal()
            }
            if exited.wait(timeout: deadline) == .timedOut {
                timedOut = true
                process.terminate()
                if exited.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
            }
        } else {
            process.waitUntilExit()
        }
        group.wait()

        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            timedOut: timedOut
        )
    }
}
