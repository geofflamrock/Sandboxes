import Foundation

/// An `sbxenv.yaml` file, as the Environments page and Home show it and as
/// creating a sandbox from it needs it
/// (https://docs.docker.com/ai/sandboxes/configuration/environment-files/).
struct EnvironmentFile: Identifiable, Hashable {
    let url: URL
    /// Whether it's in the app's environments folder, rather than a file
    /// opened from somewhere else.
    let isInLibrary: Bool
    /// The `name:` the file sets.
    var name: String?
    var agent: String?
    /// The primary workspace, as an absolute path.
    var workspace: String?
    var kits: [String] = []
    /// The arguments the file declares under `args:`, which `--env-arg` sets.
    var arguments: [KitArgument] = []
    /// Whether it runs commands on the Mac: lifecycle commands, or secrets
    /// that come from a command.
    var hasHostCommands = false
    /// Why the file couldn't be read, if it couldn't.
    var problem: String?
    var modified: Date?

    var id: URL { url }

    /// The file's name, or its folder's when it's called `sbxenv.yaml`.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return Self.fallbackName(for: url)
    }

    /// The sandbox it creates: its `name:`, or else `<agent>-<workspace folder>`,
    /// as sbx names it.
    var sandboxName: String? {
        if let name, !name.isEmpty { return name }
        guard let agent, let workspace else { return nil }
        return "\(agent)-\(URL(fileURLWithPath: workspace).lastPathComponent)"
    }

    var summary: String {
        var parts: [String] = []
        if let agent { parts.append(agent) }
        if let workspace { parts.append((workspace as NSString).abbreviatingWithTildeInPath) }
        if !kits.isEmpty { parts.append(kits.count == 1 ? "1 kit" : "\(kits.count) kits") }
        return parts.isEmpty ? (url.path as NSString).abbreviatingWithTildeInPath : parts.joined(separator: " · ")
    }

    static func fallbackName(for url: URL) -> String {
        url.lastPathComponent == "sbxenv.yaml"
            ? url.deletingLastPathComponent().lastPathComponent
            : url.deletingPathExtension().lastPathComponent
    }

    /// Reads what the app shows about `url`. A file that can't be read or
    /// parsed still appears, with the reason, so it can be opened and fixed.
    static func read(_ url: URL, isInLibrary: Bool) -> EnvironmentFile {
        var file = EnvironmentFile(url: url, isInLibrary: isInLibrary)
        file.modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            file.load(try EnvironmentYAML.parse(text))
        } catch {
            file.problem = error.localizedDescription
        }
        return file
    }

    private mutating func load(_ document: YAMLValue) {
        name = document["name"]?.string
        agent = document["agent"]?.string
        let directory = url.deletingLastPathComponent()
        let workspaceValue = document["workspace"]
        if let path = workspaceValue?.string ?? workspaceValue?["path"]?.string, !path.isEmpty {
            workspace = Self.resolve(path, against: directory)
        }
        kits = (document["kits"]?.list ?? []).compactMap { $0.string ?? $0["source"]?.string }
        arguments = (document["args"]?.map ?? []).map { entry in
            KitArgument(
                name: entry.key,
                description: entry.value["description"]?.string,
                defaultValue: entry.value["default"]?.string,
                isRequired: entry.value["required"]?.bool ?? false,
                choices: (entry.value["enum"]?.list ?? []).compactMap(\.string),
                pattern: entry.value["pattern"]?.string
            )
        }
        let lifecycle = document["lifecycle"]?.map ?? []
        let commandSecrets = (document["secrets"]?.map ?? []).contains { $0.value["command"] != nil }
        let commandRegistries = (document["registries"]?.map ?? []).contains { registry in
            ["secret", "username"].contains { registry.value[$0]?["command"] != nil }
        }
        hasHostCommands = lifecycle.contains { !($0.value.list ?? []).isEmpty } || commandSecrets || commandRegistries
    }

    /// An absolute path for `path`, which may be relative to the file's folder
    /// or start with `~`. A `${{ env.… }}` reference is left as it is.
    static func resolve(_ path: String, against directory: URL) -> String {
        if path.contains("${{") { return path }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
        return directory.appendingPathComponent(expanded).standardizedFileURL.path
    }
}

// MARK: - The New Sandbox window's options as a file

extension CreateSandboxRequest {
    /// What reading a file for the New Sandbox window found that the window
    /// can't show, so saving would lose it.
    struct UnsupportedFields: LocalizedError {
        let fields: [String]

        var errorDescription: String? {
            "It uses \(fields.map { "“\($0)”" }.formatted(.list(type: .and))), which the New Sandbox window can't show."
        }
    }

    /// The environment file Save Environment writes.
    var environmentFileText: String {
        EnvironmentYAML.write(environmentDocument)
    }

    var environmentDocument: YAMLValue {
        var entries = [YAMLEntry(key: "schemaVersion", value: .scalar("1"))]
        if !trimmedName.isEmpty {
            entries.append(YAMLEntry(key: "name", value: .scalar(trimmedName)))
        }
        // A workload kit goes in `kits`, and `agent` names it, as a v3 workload needs.
        var kitEntries: [YAMLValue] = []
        if KitArgument.isInspectable(workload: trimmedWorkload) {
            entries.append(YAMLEntry(key: "agent", value: .scalar(KitArgument.handle(for: trimmedWorkload))))
            kitEntries.append(kitEntry(for: trimmedWorkload))
        } else {
            entries.append(YAMLEntry(key: "agent", value: .scalar(trimmedWorkload)))
        }
        kitEntries += kits.map(kitEntry(for:))
        if !kitEntries.isEmpty {
            entries.append(YAMLEntry(key: "kits", value: .list(kitEntries)))
        }
        if let workspace {
            if mode == .clone {
                entries.append(YAMLEntry(key: "workspace", value: .map([
                    YAMLEntry(key: "path", value: .scalar(workspace.path)),
                    YAMLEntry(key: "clone", value: .plain("true")),
                ])))
            } else {
                entries.append(YAMLEntry(key: "workspace", value: .scalar(workspace.path)))
            }
            if !additionalWorkspaces.isEmpty {
                entries.append(YAMLEntry(key: "additionalWorkspaces", value: .list(additionalWorkspaces.map { folder in
                    YAMLValue.map([
                        YAMLEntry(key: "path", value: .scalar(folder.url.path)),
                        YAMLEntry(key: "readOnly", value: .plain(folder.isReadOnly ? "true" : "false")),
                    ])
                })))
            }
        }
        let variables = environment.filter { !$0.isBlank }
        if !variables.isEmpty {
            entries.append(YAMLEntry(key: "env", value: .map(variables.map {
                YAMLEntry(key: $0.trimmedKey, value: .scalar($0.value))
            })))
        }
        var options: [YAMLEntry] = []
        if cpus > 0 {
            options.append(YAMLEntry(key: "cpus", value: .plain(String(cpus))))
        }
        if memoryGiB > 0 {
            options.append(YAMLEntry(key: "memory", value: .scalar("\(memoryGiB)g")))
        }
        if !options.isEmpty {
            entries.append(YAMLEntry(key: "sandboxOptions", value: .map(options)))
        }
        return .map(entries)
    }

    /// A kit, with the values entered for its arguments when there are any.
    private func kitEntry(for kit: String) -> YAMLValue {
        // Until the kit has been read, keep every value, such as ones read from the file being edited.
        let declared = declaredKitArguments[kit].map { Set($0.map(\.name)) }
        let values = (kitArgumentValues[kit] ?? [:])
            .filter { (declared?.contains($0.key) ?? true) && !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
        guard !values.isEmpty else { return .scalar(kit) }
        return .map([
            YAMLEntry(key: "source", value: .scalar(kit)),
            YAMLEntry(key: "args", value: .map(values.map { YAMLEntry(key: $0.key, value: .scalar($0.value)) })),
        ])
    }

    /// The options in an environment file, for editing it in the New Sandbox
    /// window. Throws `UnsupportedFields` for anything the window can't show,
    /// rather than dropping it when the file is saved again.
    init(environmentFile document: YAMLValue, at url: URL) throws {
        self.init()
        target = .environment
        guard let entries = document.map else {
            throw UnsupportedFields(fields: ["(not a mapping)"])
        }
        let directory = url.deletingLastPathComponent()
        var unsupported: [String] = []
        var kitValues: [(reference: String, arguments: [String: String])] = []

        for entry in entries {
            let value = entry.value
            switch entry.key {
            case "schemaVersion":
                if value.string != "1" { unsupported.append("schemaVersion") }
            case "name":
                if let text = value.string, !text.contains("${{") { name = text } else { unsupported.append("name") }
            case "agent":
                if let text = value.string, !text.contains("${{") { workload = text } else { unsupported.append("agent") }
            case "kits":
                guard let items = value.list else { unsupported.append("kits"); continue }
                for item in items {
                    if let reference = item.string, !reference.contains("${{") {
                        kitValues.append((reference, [:]))
                    } else if let fields = item.map, let reference = item["source"]?.string,
                              fields.allSatisfy({ ["source", "args"].contains($0.key) }) {
                        var arguments: [String: String] = [:]
                        for argument in item["args"]?.map ?? [] {
                            guard let text = argument.value.string, !text.contains("${{") else {
                                unsupported.append("kits.args")
                                continue
                            }
                            arguments[argument.key] = text
                        }
                        kitValues.append((reference, arguments))
                    } else {
                        unsupported.append("kits")
                    }
                }
            case "workspace":
                if let path = value.string {
                    workspace = Self.workspaceURL(path, against: directory)
                    if workspace == nil { unsupported.append("workspace") }
                } else if let fields = value.map, let path = value["path"]?.string,
                          fields.allSatisfy({ ["path", "clone"].contains($0.key) }) {
                    workspace = Self.workspaceURL(path, against: directory)
                    if workspace == nil { unsupported.append("workspace") }
                    mode = value["clone"]?.bool == true ? .clone : .direct
                } else {
                    unsupported.append("workspace")
                }
            case "additionalWorkspaces":
                guard let items = value.list else { unsupported.append("additionalWorkspaces"); continue }
                for item in items {
                    guard let fields = item.map, let path = item["path"]?.string,
                          fields.allSatisfy({ ["path", "readOnly"].contains($0.key) }),
                          let url = Self.workspaceURL(path, against: directory) else {
                        unsupported.append("additionalWorkspaces")
                        continue
                    }
                    additionalWorkspaces.append(AdditionalWorkspace(url: url, isReadOnly: item["readOnly"]?.bool ?? false))
                }
            case "env":
                guard let variables = value.map else { unsupported.append("env"); continue }
                for variable in variables {
                    guard let text = variable.value.string, !text.contains("${{") else {
                        unsupported.append("env")
                        continue
                    }
                    environment.append(EnvironmentVariable(key: variable.key, value: text))
                }
            case "sandboxOptions":
                for option in value.map ?? [] {
                    switch option.key {
                    case "cpus":
                        if let count = option.value.string.flatMap({ Int($0) }), count >= 0 {
                            cpus = count
                        } else {
                            unsupported.append("sandboxOptions.cpus")
                        }
                    case "memory":
                        if let gib = option.value.string.flatMap(Self.memoryGiB(from:)) {
                            memoryGiB = gib
                        } else {
                            unsupported.append("sandboxOptions.memory")
                        }
                    default:
                        unsupported.append("sandboxOptions.\(option.key)")
                    }
                }
            default:
                unsupported.append(entry.key)
            }
        }

        // `agent` names a workload kit listed in `kits`, which becomes the workload again.
        if let index = kitValues.firstIndex(where: {
            KitArgument.isInspectable(workload: $0.reference) && KitArgument.handle(for: $0.reference) == workload
        }) {
            workload = kitValues[index].reference
            if !kitValues[index].arguments.isEmpty {
                kitArgumentValues[workload] = kitValues[index].arguments
            }
            kitValues.remove(at: index)
        }
        for kit in kitValues {
            kits.append(kit.reference)
            if !kit.arguments.isEmpty {
                kitArgumentValues[kit.reference] = kit.arguments
            }
        }

        if !unsupported.isEmpty {
            var seen: Set<String> = []
            throw UnsupportedFields(fields: unsupported.filter { seen.insert($0).inserted })
        }
    }

    private static func workspaceURL(_ path: String, against directory: URL) -> URL? {
        guard !path.contains("${{"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: EnvironmentFile.resolve(path, against: directory), isDirectory: true)
    }

    /// Whole gibibytes from a size such as `8g`, `8G` or `8192m`, which is
    /// what the Memory menu offers.
    static func memoryGiB(from text: String) -> Int? {
        guard let match = text.lowercased().wholeMatch(of: #/(\d+)\s*([gm])i?b?/#), let amount = Int(match.1) else {
            return nil
        }
        if match.2 == "g" { return amount }
        return amount % 1024 == 0 ? amount / 1024 : nil
    }
}
