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

/// Folder paths as typed or chosen in the New Sandbox window.
enum WorkspacePath {
    /// The path with `~` expanded, or nil when nothing's entered.
    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("~") ? (trimmed as NSString).expandingTildeInPath : trimmed
    }

    /// Why `text` can't be mounted, if it can't. A sandbox needs a folder
    /// that exists; an environment file may be used on another Mac, so only
    /// the form of its paths is checked.
    static func problem(with text: String, inEnvironmentFile: Bool) -> String? {
        guard let path = normalized(text) else { return nil }
        if path.contains("${{") {
            return "Enter a folder's full path rather than “\(path)”."
        }
        guard path.hasPrefix("/") else {
            return "Enter the full path of “\(path)”, starting with / or ~."
        }
        if !inEnvironmentFile {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                return "There's no folder at “\((path as NSString).abbreviatingWithTildeInPath)”."
            }
        }
        return nil
    }
}

/// An extra folder mounted alongside the main workspace.
struct AdditionalWorkspace: Identifiable, Hashable {
    let id = UUID()
    /// As typed or chosen. An empty one is left out.
    var path = ""
    var isReadOnly = true

    var normalizedPath: String? { WorkspacePath.normalized(path) }

    /// sbx mounts a path ending in `:ro` read-only.
    var argument: String {
        let path = normalizedPath ?? ""
        return isReadOnly ? path + ":ro" : path
    }
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
    /// What the New Sandbox window makes: a sandbox, or an environment file
    /// with the same options. It's set by how the window was opened.
    enum Target {
        case sandbox
        case environment
    }

    var target: Target = .sandbox
    var workload = ""
    var kits: [String] = []
    /// The main workspace as typed or chosen. Empty for none.
    var workspacePath = ""
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
    /// Hosts the sandbox is denied from the start, one per line. Commas and
    /// spaces separate them too, for a pasted list.
    var deniedHosts = ""
    /// The arguments each kit declares, by kit reference, once `sbx kit inspect` has read them.
    var declaredKitArguments: [String: [KitArgument]] = [:]
    /// Values entered for kits' arguments, by kit reference and then argument
    /// name. An argument without one is left to its default.
    var kitArgumentValues: [String: [String: String]] = [:]

    var trimmedWorkload: String { workload.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The main workspace with `~` expanded, or nil for none.
    var workspace: String? { WorkspacePath.normalized(workspacePath) }
    /// The extra folders that have a path. They're only mounted with a main workspace.
    var enteredAdditionalWorkspaces: [AdditionalWorkspace] {
        workspace == nil ? [] : additionalWorkspaces.filter { $0.normalizedPath != nil }
    }
    var deniedHostList: [String] {
        deniedHosts
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
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
        for host in deniedHostList {
            arguments += ["--deny-network", host]
        }
        arguments.append(trimmedWorkload)
        // Extra folders are positional too, so they only follow a main workspace.
        if let workspace {
            arguments.append(workspace)
            arguments += enteredAdditionalWorkspaces.map(\.argument)
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
        // The name is the environment file's folder, and the sandbox it creates.
        if target == .environment && trimmedName.isEmpty {
            return "Enter a name for the environment file."
        }
        if !trimmedName.isEmpty, let problem = Self.nameProblem(trimmedName) {
            return problem
        }
        let inEnvironmentFile = target == .environment
        if let problem = WorkspacePath.problem(with: workspacePath, inEnvironmentFile: inEnvironmentFile) {
            return problem
        }
        for folder in enteredAdditionalWorkspaces {
            if let problem = WorkspacePath.problem(with: folder.path, inEnvironmentFile: inEnvironmentFile) {
                return problem
            }
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

    /// Why sbx won't accept `name` for a sandbox, if it won't.
    static func nameProblem(_ name: String) -> String? {
        if name == "default" {
            return "The name “default” is reserved."
        }
        if name.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9.\-]+/#) == nil {
            return "Names need at least two characters, start with a letter or number, and contain only letters, numbers, hyphens and periods."
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

    static func quoteIfNeeded(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:@=+,~"))
        if !value.isEmpty && value.unicodeScalars.allSatisfy(safe.contains) {
            return value
        }
        return TerminalLauncher.shellQuote(value)
    }
}
