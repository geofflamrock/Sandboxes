import Foundation

/// A saved sandbox setup: an sbx environment file that `sbx env create`
/// builds a sandbox from
/// (https://docs.docker.com/ai/sandboxes/configuration/environment-files/).
/// Each environment is a folder holding an `sbxenv.yaml` file, named after
/// the folder.
struct SandboxEnvironment: Identifiable, Sendable {
    let name: String
    let fileURL: URL
    /// The file as written, shown so hand edits sbx understands but this
    /// app doesn't are still visible.
    let contents: String
    /// What the app understood of the file, or nil if it couldn't be read.
    let definition: Definition?
    let readError: String?

    var id: URL { fileURL }

    init(fileURL: URL) {
        self.fileURL = fileURL
        name = fileURL.deletingLastPathComponent().lastPathComponent
        var contents = ""
        var definition: Definition?
        var readError: String?
        do {
            contents = try String(contentsOf: fileURL, encoding: .utf8)
            guard let document = try YAMLReader.parse(contents) as? [String: Any] else {
                throw YAMLReader.ParseError(line: 1, message: "The file isn't a mapping of settings.")
            }
            definition = Definition(document)
        } catch {
            readError = error.localizedDescription
        }
        self.contents = contents
        self.definition = definition
        self.readError = readError
    }

    /// The agent the file names, for its icon.
    var agent: Agent? {
        guard let name = definition?.agent else { return nil }
        let workload = workloadKit?.source ?? name
        return Agent(workload: workload) ?? Agent(identifier: workload)
    }

    /// The kit that provides a v3 agent: the one the agent's name refers to,
    /// or else the first kit, where the app writes it, when the name isn't a
    /// built-in agent's.
    var workloadKit: Kit? {
        guard let name = definition?.agent, let kits = definition?.kits else { return nil }
        if let kit = kits.first(where: { $0.source == name || KitArgument.handle(for: $0.source) == name }) {
            return kit
        }
        return Agent.match(workload: name)?.version == .builtIn ? nil : kits.first
    }

    /// A path from the file, resolved the way sbx does: relative paths start
    /// from the file's folder.
    func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return fileURL.deletingLastPathComponent().appending(path: expanded).standardizedFileURL
    }
}

// MARK: - Reading

extension SandboxEnvironment {
    /// The parts of an environment file the app shows. sbx reads the rest.
    /// Like the parsers for sbx's output, this takes what it recognizes and
    /// skips anything else rather than rejecting the file.
    struct Definition: Sendable {
        var name: String?
        var agent: String?
        var args: [String: Argument] = [:]
        var kits: [Kit] = []
        var workspace: Workspace?
        var additionalWorkspaces: [Mount] = []
        var env: [String: String] = [:]
        var cpus: String?
        var memory: String?
        /// Commands sbx runs on the Mac rather than in the sandbox.
        var hostCommands: [HostCommand] = []

        init(_ document: [String: Any]) {
            name = Self.string(document["name"])
            agent = Self.string(document["agent"])
            for (key, value) in Self.mapping(document["args"]) {
                let declaration = Self.mapping(value)
                args[key] = Argument(
                    defaultValue: Self.string(declaration["default"]),
                    isRequired: Self.bool(declaration["required"]),
                    description: Self.string(declaration["description"]),
                    choices: (declaration["enum"] as? [Any] ?? []).compactMap(Self.string)
                )
            }
            for item in document["kits"] as? [Any] ?? [] {
                if let source = Self.string(item) {
                    kits.append(Kit(source: source))
                } else if let source = Self.string(Self.mapping(item)["source"]) {
                    let args = Self.mapping(Self.mapping(item)["args"]).compactMapValues(Self.string)
                    kits.append(Kit(source: source, args: args))
                }
            }
            if let path = Self.string(document["workspace"]) {
                workspace = Workspace(path: path)
            } else if let path = Self.string(Self.mapping(document["workspace"])["path"]) {
                workspace = Workspace(path: path, clone: Self.bool(Self.mapping(document["workspace"])["clone"]))
            }
            for item in document["additionalWorkspaces"] as? [Any] ?? [] {
                if let path = Self.string(item) {
                    additionalWorkspaces.append(Mount(path: path))
                } else if let path = Self.string(Self.mapping(item)["path"]) {
                    additionalWorkspaces.append(Mount(path: path, readOnly: Self.bool(Self.mapping(item)["readOnly"])))
                }
            }
            env = Self.mapping(document["env"]).compactMapValues(Self.string)
            let options = Self.mapping(document["sandboxOptions"])
            cpus = Self.string(options["cpus"])
            memory = Self.string(options["memory"])

            for (key, value) in Self.mapping(document["secrets"]).sorted(by: { $0.key < $1.key }) {
                if let command = Self.string(Self.mapping(value)["command"]) {
                    hostCommands.append(HostCommand(label: "Secret \(key)", command: command))
                }
            }
            let lifecycle = Self.mapping(document["lifecycle"])
            for phase in ["initialize", "postCreate"] {
                for hook in lifecycle[phase] as? [Any] ?? [] {
                    let hook = Self.mapping(hook)
                    if let command = Self.string(hook["command"]) {
                        hostCommands.append(HostCommand(label: Self.string(hook["name"]) ?? phase, command: command))
                    }
                }
            }
        }

        private static func string(_ value: Any?) -> String? {
            value as? String
        }

        private static func bool(_ value: Any?) -> Bool {
            ["true", "yes", "on"].contains((value as? String)?.lowercased() ?? "")
        }

        private static func mapping(_ value: Any?) -> [String: Any] {
            value as? [String: Any] ?? [:]
        }
    }

    /// A parameter the file declares, set with `--env-arg NAME=VALUE`.
    struct Argument: Sendable {
        var defaultValue: String?
        var isRequired = false
        var description: String?
        var choices: [String] = []
    }

    struct Kit: Sendable {
        var source: String
        /// Values for the kit's own arguments, as `--kit-arg` would set them.
        var args: [String: String] = [:]
    }

    struct Workspace: Sendable {
        var path: String
        var clone = false
    }

    struct Mount: Sendable {
        var path: String
        var readOnly = false
    }

    struct HostCommand: Sendable {
        var label: String
        var command: String
    }
}

// MARK: - Writing

extension SandboxEnvironment {
    /// The environment file for what's set in the New Sandbox window. Paths
    /// are absolute so the file works wherever it's kept. Environment files
    /// (`--env-file`) and static MCP servers have no equivalent, so they're
    /// left out.
    static func yaml(for request: CreateSandboxRequest) -> String {
        var lines = [
            "# Saved by Sandboxes. Create a sandbox from it with: sbx env create <this file>",
            "schemaVersion: \"1\"",
        ]
        if !request.trimmedName.isEmpty {
            lines.append("name: \(quote(request.trimmedName))")
        }
        // A v3 agent is named by its kit's name, with the kit itself listed
        // under kits below; a built-in agent by its own name.
        let workload = request.trimmedWorkload
        let isKit = KitArgument.isInspectable(workload: workload)
        let agent = isKit ? (request.workloadKitName ?? KitArgument.handle(for: workload)) : workload
        lines.append("agent: \(quote(agent))")

        if let workspace = request.workspace {
            if request.mode == .clone {
                lines += ["workspace:", "  path: \(quote(workspace.path))", "  clone: true"]
            } else {
                lines.append("workspace: \(quote(workspace.path))")
            }
            if !request.additionalWorkspaces.isEmpty {
                lines.append("additionalWorkspaces:")
                for folder in request.additionalWorkspaces {
                    lines.append("  - path: \(quote(folder.url.path))")
                    if folder.isReadOnly {
                        lines.append("    readOnly: true")
                    }
                }
            }
        }

        // An agent kit has to be listed as a kit too for sbx to find it, so
        // this is the workload when it's a kit, then the mixins.
        let kits = request.argumentKits
        if !kits.isEmpty {
            lines.append("kits:")
            for kit in kits {
                let declared = Set((request.declaredKitArguments[kit] ?? []).map(\.name))
                let values = (request.kitArgumentValues[kit] ?? [:])
                    .filter { declared.contains($0.key) && !$0.value.isEmpty }
                    .sorted { $0.key < $1.key }
                if values.isEmpty {
                    lines.append("  - \(quote(kit))")
                } else {
                    lines += ["  - source: \(quote(kit))", "    args:"]
                    lines += values.map { "      \(quote($0.key)): \(quote($0.value))" }
                }
            }
        }

        // As on the command line, a later variable with the same name wins.
        var variables: [(key: String, value: String)] = []
        for variable in request.environment where !variable.isBlank {
            variables.removeAll { $0.key == variable.trimmedKey }
            variables.append((variable.trimmedKey, variable.value))
        }
        if !variables.isEmpty {
            lines.append("env:")
            lines += variables.map { "  \($0.key): \(quote($0.value))" }
        }

        if request.cpus > 0 || request.memoryGiB > 0 {
            lines.append("sandboxOptions:")
            if request.cpus > 0 {
                lines.append("  cpus: \(request.cpus)")
            }
            if request.memoryGiB > 0 {
                lines.append("  memory: \(request.memoryGiB)g")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The name the New Sandbox window suggests: the sandbox's name if it has
    /// one, otherwise the agent and workspace, the way sbx names sandboxes.
    static func suggestedName(for request: CreateSandboxRequest) -> String {
        if !request.trimmedName.isEmpty {
            return request.trimmedName
        }
        var agent = Substring(request.trimmedWorkload)
        if let at = agent.firstIndex(of: "@") { agent = agent[..<at] }
        if let slash = agent.lastIndex(of: "/") { agent = agent[agent.index(after: slash)...] }
        if let colon = agent.firstIndex(of: ":") { agent = agent[..<colon] }
        if agent.hasPrefix("sbx-kit-") { agent = agent.dropFirst("sbx-kit-".count) }
        let parts = [String(agent), request.workspace?.lastPathComponent].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "environment" : parts.joined(separator: "-")
    }

    /// A plain YAML scalar when that reads the same, otherwise a double-quoted
    /// string, which has JSON's escapes.
    static func quote(_ value: String) -> String {
        let reserved: Set<String> = ["", "~", "null", "true", "false", "yes", "no", "on", "off", "y", "n"]
        if value.wholeMatch(of: #/[A-Za-z_/][A-Za-z0-9_./:@+-]*/#) != nil,
           !reserved.contains(value.lowercased()),
           !value.hasSuffix(":") {
            return value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value), let quoted = String(data: data, encoding: .utf8) else {
            return "\"\(value)\""
        }
        return quoted
    }
}

// MARK: - Creating

/// What's set in the New Sandbox from Environment window, as an
/// `sbx env create` command.
struct EnvironmentCreateRequest {
    let environment: SandboxEnvironment
    /// Overrides the file's name. Empty keeps it.
    var name = ""
    /// Values for the file's arguments, starting at their defaults.
    var argumentValues: [String: String] = [:]

    init(environment: SandboxEnvironment) {
        self.environment = environment
        for (key, argument) in environment.definition?.args ?? [:] {
            argumentValues[key] = argument.defaultValue ?? ""
        }
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The file's arguments in a stable order.
    var argumentNames: [String] {
        (environment.definition?.args ?? [:]).keys.sorted()
    }

    var arguments: [String] {
        // --force approves sbx's plan for the file (its secrets, bindings and
        // host commands), which otherwise needs answering in a terminal. The
        // window shows what runs before Create is clicked.
        var arguments = ["env", "create", "--force"]
        if !trimmedName.isEmpty {
            arguments += ["--name", trimmedName]
        }
        let declared = environment.definition?.args ?? [:]
        for key in argumentNames {
            let value = argumentValues[key] ?? ""
            // Only pass what differs from the file, so the command stays short.
            if value != (declared[key]?.defaultValue ?? "") || declared[key]?.isRequired == true {
                arguments += ["--env-arg", "\(key)=\(value)"]
            }
        }
        arguments.append(environment.fileURL.path)
        return arguments
    }

    var commandLine: String {
        (["sbx"] + arguments).map(CreateSandboxRequest.quoteIfNeeded).joined(separator: " ")
    }

    /// Creates an empty sandbox with the environment's agent and kits, where
    /// sbx asks to approve their credentials, as the New Sandbox window offers.
    var credentialApprovalCommandLine: String {
        var arguments = ["sbx", "create"]
        let definition = environment.definition
        let workloadKit = environment.workloadKit
        for kit in definition?.kits ?? [] where kit.source != workloadKit?.source {
            arguments += ["--kit", kit.source]
        }
        for kit in definition?.kits ?? [] {
            for (name, value) in kit.args.sorted(by: { $0.key < $1.key }) {
                arguments += ["--kit-arg", KitArgument.flag(name: name, value: value, handle: KitArgument.handle(for: kit.source))]
            }
        }
        arguments.append(workloadKit?.source ?? definition?.agent ?? "")
        return arguments.map(CreateSandboxRequest.quoteIfNeeded).joined(separator: " ")
    }

    var validationMessage: String? {
        if let message = CreateSandboxRequest.nameValidationMessage(trimmedName) {
            return message
        }
        let declared = environment.definition?.args ?? [:]
        for key in argumentNames where declared[key]?.isRequired == true {
            if (argumentValues[key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                return "Enter a value for “\(key)”."
            }
        }
        return nil
    }
}
