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

/// A folder on the Mac used for a path a kit shares with the host
/// (`host-mount@1`), instead of the folder Docker Sandboxes manages for it.
/// sbx only accepts a sandbox path that one of the kits declares.
struct HostMount: Identifiable, Hashable {
    let id = UUID()
    var sandboxPath = ""
    /// As typed or chosen.
    var hostPath = ""

    var trimmedSandboxPath: String { sandboxPath.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedHostPath: String? { WorkspacePath.normalized(hostPath) }
    var isBlank: Bool { trimmedSandboxPath.isEmpty && normalizedHostPath == nil }

    /// What `--mount` takes: `HOST:SANDBOX_PATH`.
    var spec: String { "\(normalizedHostPath ?? ""):\(trimmedSandboxPath)" }

    /// Why the mount can't be used, if it can't. A sandbox path must be
    /// absolute and canonical, as the kit spec requires of the path it declares.
    func problem(inEnvironmentFile: Bool) -> String? {
        let path = trimmedSandboxPath
        if path.isEmpty {
            return "Enter a sandbox path for each host mount."
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        if !path.hasPrefix("/") || path == "/" || path.hasSuffix("/")
            || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            return "“\(path)” isn't a sandbox path. Enter the full path the kit gives, such as /home/agent/.cache."
        }
        if path.contains(":") {
            return "The sandbox path “\(path)” can't contain a colon."
        }
        guard normalizedHostPath != nil else {
            return "Choose a folder on your Mac for “\(path)”."
        }
        if hostPath.contains(":") {
            return "The folder for “\(path)” can't have a colon in its path."
        }
        return WorkspacePath.problem(with: hostPath, inEnvironmentFile: inEnvironmentFile)
    }
}

struct EnvironmentVariable: Identifiable, Hashable {
    let id = UUID()
    var key = ""
    var value = ""

    var trimmedKey: String { key.trimmingCharacters(in: .whitespaces) }
    var isBlank: Bool { trimmedKey.isEmpty && value.isEmpty }
}

/// A sandbox port to publish on the Mac, as entered in the New Sandbox
/// window or the Publish Port sheet. sbx binds it to localhost over IPv4.
struct PortMapping: Identifiable, Hashable {
    let id = UUID()
    /// Empty for a free port that sbx picks.
    var hostPort = ""
    var sandboxPort = ""

    var trimmedHostPort: String { hostPort.trimmingCharacters(in: .whitespaces) }
    var trimmedSandboxPort: String { sandboxPort.trimmingCharacters(in: .whitespaces) }
    var isBlank: Bool { trimmedHostPort.isEmpty && trimmedSandboxPort.isEmpty }

    /// What `--publish` takes: `[HOST_PORT:]SANDBOX_PORT`.
    var spec: String {
        trimmedHostPort.isEmpty ? trimmedSandboxPort : "\(trimmedHostPort):\(trimmedSandboxPort)"
    }

    /// Why the ports can't be published, if they can't.
    var problem: String? {
        if trimmedSandboxPort.isEmpty {
            return "Enter a sandbox port for each port."
        }
        for text in [trimmedSandboxPort, trimmedHostPort] where !text.isEmpty && Self.number(text) == nil {
            return "“\(text)” isn't a port. Ports are numbers from 1 to 65535."
        }
        return nil
    }

    static func number(_ text: String) -> Int? {
        Int(text).flatMap { (1...65535).contains($0) ? $0 : nil }
    }
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

/// A disk sbx sizes when it creates a sandbox. `sbx create` has no flags for
/// these yet, only environment variables it reads when it runs.
enum SandboxDisk: CaseIterable {
    case system
    case docker
    case clonedWorkspace

    var environmentVariable: String {
        switch self {
        case .system: "DOCKER_SANDBOXES_ROOT_SIZE"
        case .docker: "DOCKER_SANDBOXES_DOCKER_SIZE"
        case .clonedWorkspace: "DOCKER_SANDBOXES_CLONED_WORKSPACE_SIZE"
        }
    }

    /// Sizes to choose from, in GB, leaving out the 20 GB system and 10 GB
    /// Docker data disks that Docker's docs say sbx gives by default.
    var choices: [Int] {
        switch self {
        case .system: [30, 40, 60, 80, 120, 160, 250]
        case .docker: [5, 20, 40, 60, 80, 120]
        case .clonedWorkspace: [10, 20, 50, 100, 200, 500]
        }
    }
}

/// A disk size picked from the choices, or typed. sbx checks a typed size
/// when it creates the sandbox, so it's passed on as it is.
enum DiskSize: Hashable {
    case gib(Int)
    case custom(String)

    /// What sbx is given, or nil when a custom size is empty.
    var value: String? {
        switch self {
        case let .gib(gib):
            return "\(gib)g"
        case let .custom(text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
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
    /// Folders on the Mac for paths the kits share with the host.
    var hostMounts: [HostMount] = []
    var name = ""
    /// 0 lets sbx choose: all of the Mac's CPUs.
    var cpus = 0
    /// In GiB. 0 lets sbx choose.
    var memoryGiB = 0
    /// A disk that isn't here is left to sbx.
    var diskSizes: [SandboxDisk: DiskSize] = [:]
    var environment: [EnvironmentVariable] = []
    var environmentFiles: [URL] = []
    /// How the agent sees sbx's shared skills store. Nil leaves it to sbx's
    /// default, which is read only unless the skills.defaultMode setting says otherwise.
    var skillsMode: SkillsMode?
    /// MCP servers to load when the sandbox starts. Choosing any makes the
    /// set fixed: the agent can't find and load other servers itself.
    var staticMCPServers: [String] = []
    /// Sandbox ports to publish on the Mac.
    var ports: [PortMapping] = []
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
    var enteredPorts: [PortMapping] {
        ports.filter { !$0.isBlank }
    }
    var enteredHostMounts: [HostMount] {
        hostMounts.filter { !$0.isBlank }
    }
    /// The host mounts to offer next time.
    var recentHostMounts: [RecentHostMount] {
        enteredHostMounts.compactMap { mount in
            mount.normalizedHostPath.map { RecentHostMount(sandboxPath: mount.trimmedSandboxPath, hostPath: $0) }
        }
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
        if let skillsMode {
            arguments += ["--skills", skillsMode.rawValue]
        }
        for kit in kits {
            arguments += ["--kit", kit]
        }
        arguments += kitArgumentFlags
        for mount in enteredHostMounts {
            arguments += ["--mount", mount.spec]
        }
        for server in staticMCPServers {
            arguments += ["--static-mcp", server]
        }
        for port in enteredPorts {
            arguments += ["--publish", port.spec]
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

    /// The disks this request sizes: the cloned workspace only when there's a
    /// workspace to clone. Environment files can't set disk sizes.
    var sizedDisks: [SandboxDisk] {
        guard target == .sandbox else { return [] }
        return SandboxDisk.allCases.filter { disk in
            disk != .clonedWorkspace || (workspace != nil && mode == .clone)
        }
    }

    /// Variables set for the `sbx create` process only, not in the sandbox,
    /// in the order the command line shows them.
    var processEnvironment: [(key: String, value: String)] {
        sizedDisks.compactMap { disk in
            guard let value = diskSizes[disk]?.value else { return nil }
            return (key: disk.environmentVariable, value: value)
        }
    }

    /// The command as typed in a terminal, with the process's variables in front of it.
    var commandLine: String {
        let variables = processEnvironment.map { "\($0.key)=\(Self.quoteIfNeeded($0.value))" }
        return (variables + (["sbx"] + arguments).map(Self.quoteIfNeeded)).joined(separator: " ")
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
        for mount in enteredHostMounts {
            if let problem = mount.problem(inEnvironmentFile: inEnvironmentFile) {
                return problem
            }
        }
        let sandboxPaths = enteredHostMounts.map(\.trimmedSandboxPath)
        if let repeated = sandboxPaths.first(where: { path in sandboxPaths.filter { $0 == path }.count > 1 }) {
            return "“\(repeated)” has more than one host mount."
        }
        for variable in environment where !variable.isBlank {
            if variable.trimmedKey.isEmpty {
                return "Enter a name for each environment variable."
            }
            if variable.trimmedKey.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9_]*/#) == nil {
                return "“\(variable.trimmedKey)” isn't a valid environment variable name."
            }
        }
        for port in enteredPorts {
            if let problem = port.problem {
                return problem
            }
        }
        let hostPorts = enteredPorts.map(\.trimmedHostPort).filter { !$0.isEmpty }
        if let repeated = hostPorts.first(where: { port in hostPorts.filter { $0 == port }.count > 1 }) {
            return "Host port \(repeated) is used more than once."
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
