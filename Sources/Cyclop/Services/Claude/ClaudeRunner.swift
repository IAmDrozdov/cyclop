import Foundation

/// How a `claude` run ended.
struct ClaudeRun: Equatable, Sendable {
    var status: Int32
    /// The tail of its standard error.
    var standardError: String
    var timedOut = false
}

/// Starts `claude -p` for a hand-off: the one process Cyclop starts for the Claude tab.
protocol ClaudeRunning: Sendable {
    func run(
        executable: URL, arguments: [String], folder: URL, environment: [String: String], timeout: TimeInterval
    ) async -> ClaudeRun
}

struct SystemClaudeRunner: ClaudeRunning {
    /// How long a step gets to exit after SIGTERM before it is killed.
    var grace: TimeInterval = 5

    func run(
        executable: URL, arguments: [String], folder: URL, environment: [String: String], timeout: TimeInterval
    ) async -> ClaudeRun {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: Self.runBlocking(
                        executable: executable, arguments: arguments, folder: folder, environment: environment,
                        timeout: timeout, grace: grace))
            }
        }
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ more: Data) {
            lock.lock()
            data.append(more)
            if data.count > 64 * 1024 { data = data.suffix(32 * 1024) }
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static func runBlocking(
        executable: URL, arguments: [String], folder: URL, environment: [String: String], timeout: TimeInterval,
        grace: TimeInterval
    ) -> ClaudeRun {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe
        let buffer = Buffer()
        let drained = DispatchSemaphore(value: 0)
        // Not read to the end: a helper of claude that keeps the pipe open must not hold the run.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                drained.signal()
            } else {
                buffer.append(data)
            }
        }
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return ClaudeRun(status: -1, standardError: error.localizedDescription)
        }
        var timedOut = false
        if ended.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if ended.wait(timeout: .now() + grace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = ended.wait(timeout: .now() + grace)
            }
        }
        // The handler delivers the last lines before the end of the pipe; a helper that holds the pipe open gets a second.
        _ = drained.wait(timeout: .now() + 1)
        pipe.fileHandleForReading.readabilityHandler = nil
        let status = process.isRunning ? -1 : process.terminationStatus
        return ClaudeRun(status: status, standardError: buffer.text, timedOut: timedOut)
    }
}
