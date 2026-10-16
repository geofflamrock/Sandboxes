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

/// An extra folder mounted alongside the main workspace.
struct AdditionalWorkspace: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var isReadOnly = true

    /// sbx mounts a path ending in `:ro` read-only.
    var argument: String { isReadOnly ? url.path + ":ro" : url.path }
}

struct EnvironmentVariable: Identifiable, Hashable {
    let id = UUID()
    var key = ""
    var value = ""

    var trimmedKey: String { key.trimmingCharacters(in: .whitespaces) }
    var isBlank: Bool { trimmedKey.isEmpty && value.isEmpty }
}

/// The Mac's CPUs and memory, for the limits and defaults sbx applies.
enum HostResources {
    static let cpuCount = ProcessInfo.processInfo.activeProcessorCount

    private static let memoryGiB = Double(ProcessInfo.processInfo.physicalMemory) / Double(1 << 30)

    /// What sbx gives a sandbox by default: half the Mac's memory, between 512 MiB and 32 GiB.
    static let defaultMemoryGiB = min(max(memoryGiB / 2, 0.5), 32)

    /// The most sbx allows: three quarters of the Mac's memory.
    static let maxMemoryGiB = max(Int(memoryGiB * 0.75), 1)
}

struct CreateSandboxRequest {
    var workload = ""
    var kits: [String] = []
    var workspace: URL?
    var mode: WorkspaceMode = .direct
    var additionalWorkspaces: [AdditionalWorkspace] = []
    var name = ""
    /// 0 lets sbx choose: all of the Mac's CPUs.
    var cpus = 0
    /// In GiB. 0 lets sbx choose.
    var memoryGiB = 0
    var environment: [EnvironmentVariable] = []
    var environmentFiles: [URL] = []
    /// MCP servers to load when the sandbox starts. Choosing any makes the
    /// set fixed: the agent can't find and load other servers itself.
    var staticMCPServers: [String] = []
    /// The arguments each kit declares, by kit reference, once `sbx kit inspect` has read them.
    var declaredKitArguments: [String: [KitArgument]] = [:]
    /// Values entered for kits' arguments, by kit reference and then argument
    /// name. An argument without one is left to its default.
    var kitArgumentValues: [String: [String: String]] = [:]
    /// Whether to also save this setup as an environment once the sandbox is
    /// created, and its name. An empty name uses the suggested one.
    var savesEnvironment = false
    var environmentName = ""

    var trimmedWorkload: String { workload.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var suggestedEnvironmentName: String { SandboxEnvironment.suggestedName(for: self) }

    /// The environment name to save under: what's typed, or the suggestion.
    var resolvedEnvironmentName: String {
        let typed = environmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? suggestedEnvironmentName : typed
    }

    var arguments: [String] {
        var arguments = ["create"]
        if !trimmedName.isEmpty {
            arguments += ["--name", trimmedName]
        }
        if workspace != nil && mode == .clone {
            arguments.append("--clone")
        }
        if cpus > 0 {
            arguments += ["--cpus", String(cpus)]
        }
        if memoryGiB > 0 {
            arguments += ["--memory", "\(memoryGiB)g"]
        }
        for variable in environment where !variable.isBlank {
            arguments += ["--env", "\(variable.trimmedKey)=\(variable.value)"]
        }
        for file in environmentFiles {
            arguments += ["--env-file", file.path]
        }
        for kit in kits {
            arguments += ["--kit", kit]
        }
        arguments += kitArgumentFlags
        for server in staticMCPServers {
            arguments += ["--static-mcp", server]
        }
        arguments.append(trimmedWorkload)
        // Extra folders are positional too, so they only follow a main workspace.
        if let workspace {
            arguments.append(workspace.path)
            arguments += additionalWorkspaces.map(\.argument)
        }
        return arguments
    }

    var commandLine: String {
        (["sbx"] + arguments).map(Self.quoteIfNeeded).joined(separator: " ")
    }

    /// Creates an empty sandbox with the same agent and kits, which is where
    /// sbx asks to approve their credentials: `sbx run` doesn't ask.
    var credentialApprovalCommandLine: String {
        var arguments = ["sbx", "create"]
        for kit in kits {
            arguments += ["--kit", kit]
        }
        arguments += kitArgumentFlags
        arguments.append(trimmedWorkload)
        return arguments.map(Self.quoteIfNeeded).joined(separator: " ")
    }

    /// Why the request can't be submitted yet, if it can't.
    var validationMessage: String? {
        if trimmedWorkload.isEmpty {
            return "Choose an agent or enter an image."
        }
        if let message = Self.nameValidationMessage(trimmedName) {
            return message
        }
        for variable in environment where !variable.isBlank {
            if variable.trimmedKey.isEmpty {
                return "Enter a name for each environment variable."
            }
            if variable.trimmedKey.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9_]*/#) == nil {
                return "“\(variable.trimmedKey)” isn't a valid environment variable name."
            }
        }
        for kit in argumentKits {
            for argument in declaredKitArguments[kit] ?? [] {
                if let problem = argument.problem(with: kitArgumentValues[kit]?[argument.name]) {
                    return problem
                }
            }
        }
        return nil
    }

    /// The workload, when it's a kit, then the mixins: the kits whose arguments can be set.
    var argumentKits: [String] {
        (KitArgument.isInspectable(workload: trimmedWorkload) ? [trimmedWorkload] : []) + kits
    }

    /// Records what `kit` declares. A required toggle without a default
    /// starts off, which has to be passed as `false`.
    mutating func setDeclaredArguments(_ arguments: [KitArgument], for kit: String) {
        declaredKitArguments[kit] = arguments
        for argument in arguments where argument.input == .toggle && argument.isRequired && argument.defaultValue == nil {
            if kitArgumentValues[kit]?[argument.name] == nil {
                kitArgumentValues[kit, default: [:]][argument.name] = "false"
            }
        }
    }

    /// `--kit-arg` for each value entered. A name that more than one picked
    /// kit declares is aimed at its kit, since a bare name sets it on all of them.
    private var kitArgumentFlags: [String] {
        let kits = argumentKits
        var flags: [String] = []
        for kit in kits {
            let declared = Set((declaredKitArguments[kit] ?? []).map(\.name))
            for (name, value) in (kitArgumentValues[kit] ?? [:]).sorted(by: { $0.key < $1.key })
            where declared.contains(name) && !value.isEmpty {
                let shared = kits.contains { other in
                    other != kit && declaredKitArguments[other]?.contains { $0.name == name } == true
                }
                let handle = shared ? KitArgument.handle(for: kit) : nil
                flags += ["--kit-arg", KitArgument.flag(name: name, value: value, handle: handle)]
            }
        }
        return flags
    }

    /// Why sbx won't accept `name` for a sandbox, if it won't. Empty lets sbx choose.
    static func nameValidationMessage(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if name == "default" {
            return "The name “default” is reserved."
        }
        if name.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9.\-]+/#) == nil {
            return "Names need at least two characters, start with a letter or number, and contain only letters, numbers, hyphens and periods."
        }
        return nil
    }

    static func quoteIfNeeded(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:@=+,~"))
        if !value.isEmpty && value.unicodeScalars.allSatisfy(safe.contains) {
            return value
        }
        return TerminalLauncher.shellQuote(value)
    }
}
