import Foundation

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case direct
    case clone

    var id: Self { self }

    var title: String {
        switch self {
        case .direct: "Direct"
        case .clone: "Clone"
        }
    }

    var explanation: String {
        switch self {
        case .direct:
            "The folder is mounted into the sandbox, so changes appear on your Mac immediately."
        case .clone:
            "The sandbox works on a private clone of the folder's Git repository. Fetch its commits from the sandbox-<name> remote."
        }
    }
}

struct CreateSandboxRequest {
    var workload = ""
    var kits: [String] = []
    var workspace: URL?
    var mode: WorkspaceMode = .direct
    var name = ""

    var trimmedWorkload: String { workload.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var arguments: [String] {
        var arguments = ["create"]
        if !trimmedName.isEmpty {
            arguments += ["--name", trimmedName]
        }
        if workspace != nil && mode == .clone {
            arguments.append("--clone")
        }
        for kit in kits {
            arguments += ["--kit", kit]
        }
        arguments.append(trimmedWorkload)
        if let workspace {
            arguments.append(workspace.path)
        }
        return arguments
    }

    var commandLine: String {
        (["sbx"] + arguments).map(Self.quoteIfNeeded).joined(separator: " ")
    }

    /// Why the request can't be submitted yet, if it can't.
    var validationMessage: String? {
        if trimmedWorkload.isEmpty {
            return "Choose an agent or enter an image."
        }
        if !trimmedName.isEmpty {
            if trimmedName == "default" {
                return "The name “default” is reserved."
            }
            if trimmedName.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9.\-]+/#) == nil {
                return "Names need at least two characters, start with a letter or number, and contain only letters, numbers, hyphens and periods."
            }
        }
        return nil
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:@=+,~"))
        if !value.isEmpty && value.unicodeScalars.allSatisfy(safe.contains) {
            return value
        }
        return TerminalLauncher.shellQuote(value)
    }
}
