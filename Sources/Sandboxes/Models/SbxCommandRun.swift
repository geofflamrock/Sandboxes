import Foundation
import Observation

/// One run of an sbx command that fixes the setup, such as starting the
/// daemon or signing in, with its streamed output for the command sheet.
@MainActor
@Observable
final class SbxCommandRun: Identifiable {
    enum Kind {
        case startDaemon
        case signIn

        var arguments: [String] {
            switch self {
            case .startDaemon: ["daemon", "start", "--detach"]
            case .signIn: ["login"]
            }
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

    @ObservationIgnored private var task: Task<Void, Never>?

    var commandLine: String {
        (["sbx"] + kind.arguments).joined(separator: " ")
    }

    init(kind: Kind) {
        self.kind = kind
    }

    func start(onSuccess: @escaping @MainActor () -> Void) {
        let arguments = kind.arguments
        output.append("$ \(commandLine)\n\n")
        task = Task {
            do {
                let exitCode = try await SbxCLI.stream(arguments) { [weak self] text in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.receive(text) }
                    }
                }
                if Task.isCancelled {
                    phase = .cancelled
                } else if exitCode == 0 {
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

    private func receive(_ text: String) {
        output.append(text)
        if kind == .signIn, deviceSignIn == nil {
            deviceSignIn = Self.deviceSignIn(in: output.text)
        }
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
