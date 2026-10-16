import Foundation
import Yams

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
            definition = try YAMLDecoder().decode(Definition.self, from: contents)
        } catch let error as DecodingError {
            readError = Self.describe(error)
        } catch {
            readError = error.localizedDescription
        }
        self.contents = contents
        self.definition = definition
        self.readError = readError
    }

    /// The agent the file names, for its icon.
    var agent: Agent? {
        guard let workload = definition?.agent else { return nil }
        return Agent(workloadImage: workload) ?? Agent(identifier: workload)
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

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case let .typeMismatch(_, context), let .valueNotFound(_, context),
             let .keyNotFound(_, context), let .dataCorrupted(context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

// MARK: - Reading

extension SandboxEnvironment {
    /// The parts of an environment file the app shows. sbx reads the rest.
    struct Definition: Decodable, Sendable {
        var name: String?
        var agent: String?
        var args: [String: Argument]?
        var kits: [Kit]?
        var workspace: Workspace?
        var additionalWorkspaces: [Mount]?
        var env: [String: String]?
        var sandboxOptions: Options?
        var secrets: [String: Secret]?
        var lifecycle: [String: [LifecycleCommand]]?
    }

    /// A parameter the file declares, set with `--env-arg NAME=VALUE`.
    struct Argument: Decodable, Sendable {
        var defaultValue: String?
        var required: Bool?
        var description: String?
        var choices: [String]?

        enum CodingKeys: String, CodingKey {
            case defaultValue = "default"
            case required
            case description
            case choices = "enum"
        }
    }

    /// A kit, written as a reference or as `{source, args}`.
    struct Kit: Decodable, Sendable {
        var source: String

        init(from decoder: Decoder) throws {
            if let source = try? decoder.singleValueContainer().decode(String.self) {
                self.source = source
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            source = try container.decode(String.self, forKey: .source)
        }

        enum CodingKeys: String, CodingKey {
            case source
        }
    }

    /// The main workspace, written as a path or as `{path, clone}`.
    struct Workspace: Decodable, Sendable {
        var path: String
        var clone = false

        init(from decoder: Decoder) throws {
            if let path = try? decoder.singleValueContainer().decode(String.self) {
                self.path = path
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            clone = try container.decodeIfPresent(Bool.self, forKey: .clone) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case path
            case clone
        }
    }

    struct Mount: Decodable, Sendable {
        var path: String
        var readOnly: Bool?
    }

    struct Options: Decodable, Sendable {
        // Strings, since either can be an `${{ env.args.… }}` expression.
        var cpus: String?
        var memory: String?
    }

    /// A credential sbx provisions. Only a command runs anything on the Mac.
    struct Secret: Decodable, Sendable {
        var command: String?
    }

    struct LifecycleCommand: Decodable, Sendable {
        var command: String
        var name: String?
    }
}

// MARK: - Writing

extension SandboxEnvironment {
    /// The environment file for what's set in the create sheet. Paths are
    /// absolute so the file works wherever it's kept. Environment files
    /// passed with `--env-file` have no equivalent, so they're left out.
    static func yaml(for request: CreateSandboxRequest) -> String {
        var lines = [
            "# Saved by Sandboxes. Create a sandbox from it with: sbx env create <this file>",
            "schemaVersion: \"1\"",
        ]
        if !request.trimmedName.isEmpty {
            lines.append("name: \(quote(request.trimmedName))")
        }
        lines.append("agent: \(quote(request.trimmedWorkload))")

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

        if !request.kits.isEmpty {
            lines.append("kits:")
            lines += request.kits.map { "  - \(quote($0))" }
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

    /// The name the create sheet suggests: the sandbox's name if it has one,
    /// otherwise the agent and workspace, the way sbx names sandboxes.
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
    private static func quote(_ value: String) -> String {
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

/// What's set in the create-from-environment sheet, as an `sbx env create`
/// command.
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
        // sheet shows what runs before Create is clicked.
        var arguments = ["env", "create", "--force"]
        if !trimmedName.isEmpty {
            arguments += ["--name", trimmedName]
        }
        let declared = environment.definition?.args ?? [:]
        for key in argumentNames {
            let value = argumentValues[key] ?? ""
            // Only pass what differs from the file, so the command stays short.
            if value != (declared[key]?.defaultValue ?? "") || declared[key]?.required == true {
                arguments += ["--env-arg", "\(key)=\(value)"]
            }
        }
        arguments.append(environment.fileURL.path)
        return arguments
    }

    var commandLine: String {
        (["sbx"] + arguments).map(CreateSandboxRequest.quoteIfNeeded).joined(separator: " ")
    }

    var validationMessage: String? {
        if let message = CreateSandboxRequest.nameValidationMessage(trimmedName) {
            return message
        }
        let declared = environment.definition?.args ?? [:]
        for key in argumentNames where declared[key]?.required == true {
            if (argumentValues[key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                return "Enter a value for “\(key)”."
            }
        }
        return nil
    }
}
