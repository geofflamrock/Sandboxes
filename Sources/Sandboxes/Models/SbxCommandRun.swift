import Foundation
import Observation

/// One run of a command that fixes the setup, such as installing sbx with
/// Homebrew, starting the daemon or signing in, that authorises an MCP
/// server, or that restarts the daemon after a settings change, with its
/// streamed output for the command sheet.
@MainActor
@Observable
final class SbxCommandRun: Identifiable {
    enum Kind: Equatable {
        case install
        /// Upgrades the Homebrew cask that installed sbx, such as `sbx` or `sbx@rc`.
        case upgrade(cask: String)
        case startDaemon
        /// After changing a setting that only applies once the daemon restarts.
        case restartDaemon
        case signIn
        /// `sbx mcp auth`, which opens the server's authorisation page in the
        /// browser and waits until it's approved or refused.
        case authoriseMCP(server: String)

        /// Whether it runs `brew` rather than `sbx`.
        var usesHomebrew: Bool {
            switch self {
            case .install, .upgrade: true
            case .startDaemon, .restartDaemon, .signIn, .authoriseMCP: false
            }
        }

        var arguments: [String] {
            switch self {
            case .install: ["install", "docker/tap/sbx"]
            case let .upgrade(cask): ["upgrade", "docker/tap/\(cask)"]
            case .startDaemon: ["daemon", "start", "--detach"]
            case .restartDaemon: ["daemon", "restart"]
            case .signIn: ["login"]
            case let .authoriseMCP(server): ["mcp", "auth", server]
            }
        }

        /// What to run in a terminal to do the same, such as
        /// `brew install docker/tap/sbx`.
        var commandLine: String {
            ([usesHomebrew ? "brew" : "sbx"] + arguments).joined(separator: " ")
        }
    }

    enum Phase: Equatable {
        case running
        case succeeded
        case failed(String)
        case cancelled
    }

    /// A device sign-in: sbx prints a one-time code and a page to enter it on,
    /// then waits until that's done in the browser.
    struct DeviceSignIn: Equatable {
        let code: String
        let url: URL
    }

    let id = UUID()
    let kind: Kind
    let output = ConsoleOutput()
    private(set) var phase: Phase = .running
    /// The code and page from `sbx login`, once it has printed them.
    private(set) var deviceSignIn: DeviceSignIn?
    /// The page `sbx mcp auth` opened, once it has printed it.
    private(set) var authorisationURL: URL?

    @ObservationIgnored private var task: Task<Void, Never>?

    var commandLine: String { kind.commandLine }

    init(kind: Kind) {
        self.kind = kind
    }

    func start(onSuccess: @escaping @MainActor () -> Void) {
        let kind = kind
        output.append("$ \(commandLine)\n\n")
        task = Task {
            do {
                let onOutput: @Sendable (String) -> Void = { [weak self] text in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.receive(text) }
                    }
                }
                let exitCode: Int32
                if kind.usesHomebrew {
                    guard let brew = Homebrew.executableURL() else {
                        throw HomebrewNotFound()
                    }
                    exitCode = try await SbxCLI.stream(executable: brew, arguments: kind.arguments, onOutput: onOutput)
                } else {
                    exitCode = try await SbxCLI.stream(kind.arguments, onOutput: onOutput)
                }
                if Task.isCancelled {
                    phase = .cancelled
                } else if exitCode == 0 {
                    phase = .succeeded
                    onSuccess()
                } else {
                    phase = .failed("\(kind.usesHomebrew ? "brew" : "sbx") exited with code \(exitCode).")
                }
            } catch {
                phase = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
        }
    }

    struct HomebrewNotFound: LocalizedError {
        var errorDescription: String? { "Homebrew isn't installed." }
    }

    func cancel() {
        task?.cancel()
    }

    private func receive(_ text: String) {
        output.append(text)
        if kind == .signIn, deviceSignIn == nil {
            deviceSignIn = Self.deviceSignIn(in: output.text)
        }
        if case .authoriseMCP = kind, authorisationURL == nil {
            authorisationURL = Self.authorisationURL(in: output.text)
        }
    }

    /// Finds the page in output such as:
    ///
    ///     Open this URL to authorize MCP server "linear":
    ///     https://mcp.linear.app/authorize?…
    nonisolated static func authorisationURL(in text: String) -> URL? {
        guard let prompt = text.range(of: "Open this URL") else { return nil }
        return text[prompt.upperBound...]
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
            .flatMap { URL(string: $0) }
    }

    /// Finds the sign-in page in output such as:
    ///
    ///     Your one-time device confirmation code is: EFGH-ABCD
    ///     Open this URL to sign in: https://login.docker.com/activate?user_code=EFGH-ABCD
    nonisolated static func deviceSignIn(in text: String) -> DeviceSignIn? {
        guard let match = text.firstMatch(of: #/https://\S+/activate\S*/#),
              let url = URL(string: String(match.output)),
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "user_code" })?.value
                ?? text.firstMatch(of: #/code is:\s*([A-Z0-9]{4}-[A-Z0-9]{4})/#).map({ String($0.1) })
        else { return nil }
        return DeviceSignIn(code: code, url: url)
    }
}
