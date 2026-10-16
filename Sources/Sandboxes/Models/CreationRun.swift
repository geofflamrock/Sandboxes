import Foundation
import Observation

/// One run of `sbx create`, with its streamed output.
@MainActor
@Observable
final class CreationRun {
    enum Phase: Equatable {
        case running
        case succeeded
        case failed(String)
        case cancelled
    }

    let commandLine: String
    let output = ConsoleOutput()
    private(set) var phase: Phase = .running
    /// Whether sbx withheld a credential because it hasn't been approved on
    /// this Mac. sbx only asks for approval in a terminal, so a run without
    /// one declines.
    private(set) var withheldCredential = false

    @ObservationIgnored private let arguments: [String]
    @ObservationIgnored private var task: Task<Void, Never>?

    init(request: CreateSandboxRequest) {
        commandLine = request.commandLine
        arguments = request.arguments
    }

    func start(onSuccess: @escaping @MainActor () -> Void) {
        let arguments = arguments
        let output = output
        output.append("$ \(commandLine)\n\n")
        task = Task {
            do {
                let exitCode = try await SbxCLI.stream(arguments) { text in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { output.append(text) }
                    }
                }
                if Task.isCancelled {
                    phase = .cancelled
                } else if exitCode == 0 {
                    withheldCredential = output.lines.contains(where: CredentialBindingWarning.matches)
                    phase = .succeeded
                    onSuccess()
                } else {
                    phase = .failed("sbx exited with code \(exitCode).")
                }
            } catch {
                phase = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

/// Recognizes the warning sbx prints when it starts a sandbox without a
/// credential a kit asked for, because no binding approves it yet. The wording
/// isn't documented, so this looks for the gist rather than an exact message.
enum CredentialBindingWarning {
    static func matches(_ line: String) -> Bool {
        let line = line.lowercased()
        guard line.contains("credential") || line.contains("secret") else { return false }
        return ["binding", "approv", "not sent", "withheld"].contains { line.contains($0) }
    }
}

/// Terminal-style text buffer: strips ANSI escapes and treats a lone carriage
/// return as "rewrite the current line" so progress bars don't pile up.
@MainActor
@Observable
final class ConsoleOutput {
    private(set) var lines: [String] = [""]
    @ObservationIgnored private var overwritePending = false

    var text: String { lines.joined(separator: "\n") }

    func append(_ raw: String) {
        var lines = self.lines
        for character in Self.stripANSI(raw) {
            switch character {
            case "\n", "\r\n":
                lines.append("")
                overwritePending = false
            case "\r":
                overwritePending = true
            default:
                if overwritePending {
                    lines[lines.count - 1] = ""
                    overwritePending = false
                }
                lines[lines.count - 1].append(character)
            }
        }
        self.lines = lines
    }

    private static let ansiPattern = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]"
    )

    private static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return ansiPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
