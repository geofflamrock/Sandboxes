import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let output: String

    var succeeded: Bool { exitCode == 0 }
}

enum SbxError: LocalizedError {
    case executableNotFound
    case commandFailed(arguments: [String], exitCode: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "The sbx command couldn't be found. Install the Docker Sandboxes CLI, or set its location in Settings."
        case let .commandFailed(arguments, exitCode, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                let command = (["sbx"] + arguments).joined(separator: " ")
                return "\(command) exited with code \(exitCode)."
            }
            return trimmed
        }
    }
}

/// Runs the `sbx` command line tool.
enum SbxCLI {
    static let executablePathKey = "sbxExecutablePath"

    /// The configured sbx path from Settings, or the first `sbx` on the search path.
    static func executableURL() -> URL? {
        let fileManager = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: executablePathKey)?
            .trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            let path = (custom as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for directory in ShellEnvironment.searchPath.split(separator: ":") {
            let path = "\(directory)/sbx"
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static func run(_ arguments: [String]) async throws -> CommandResult {
        let collector = OutputCollector()
        let exitCode = try await stream(arguments) { collector.append($0) }
        return CommandResult(exitCode: exitCode, output: collector.text)
    }

    /// Runs the command and throws if it exits with a non-zero status.
    @discardableResult
    static func runChecked(_ arguments: [String]) async throws -> String {
        let result = try await run(arguments)
        guard result.succeeded else {
            throw SbxError.commandFailed(arguments: arguments, exitCode: result.exitCode, output: result.output)
        }
        return result.output
    }

    /// Runs the command, passing combined stdout and stderr to `onOutput` as it
    /// arrives. Cancelling the calling task terminates the process.
    static func stream(
        _ arguments: [String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        guard let executable = executableURL() else {
            throw SbxError.executableNotFound
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ShellEnvironment.environment
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let decoder = StreamDecoder(onOutput: onOutput)
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                decoder.feed(data)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { process in
                    // Don't wait for EOF: a daemon started by sbx can inherit the
                    // pipe and hold it open. Give pending output a moment to arrive.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                        handle.readabilityHandler = nil
                        decoder.flush()
                        continuation.resume(returning: process.terminationStatus)
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    handle.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

/// Converts pipe data into text, holding back any partial line so multi-byte
/// characters aren't split between chunks.
private final class StreamDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onOutput: @Sendable (String) -> Void

    init(onOutput: @escaping @Sendable (String) -> Void) {
        self.onOutput = onOutput
    }

    func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        guard let lastBreak = buffer.lastIndex(where: { $0 == 0x0A || $0 == 0x0D }) else {
            if buffer.count > 4096 { emitAll() }
            return
        }
        let complete = buffer[buffer.startIndex...lastBreak]
        buffer = Data(buffer[buffer.index(after: lastBreak)...])
        onOutput(String(decoding: complete, as: UTF8.self))
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        emitAll()
    }

    private func emitAll() {
        guard !buffer.isEmpty else { return }
        onOutput(String(decoding: buffer, as: UTF8.self))
        buffer.removeAll()
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage += text
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
