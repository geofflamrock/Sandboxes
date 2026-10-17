import Foundation

/// A secret stored by sbx: an API key or token for a built-in service, a
/// custom secret for any other host, or pull credentials for a container
/// registry. sbx shows at most a masked value.
struct SbxSecret: Identifiable, Hashable {
    enum Kind: Hashable {
        case service
        /// Set with `sbx secret set-custom`: the sandbox sees a placeholder
        /// and the proxy swaps in the real value for requests to its hosts.
        case custom
        case registry
        /// Anything else `sbx secret ls` lists, such as MCP credentials,
        /// which the app shows but doesn't change.
        case other(String)
    }

    enum Scope: Hashable {
        /// Every sandbox. Service secrets reach existing sandboxes straight
        /// away; registry credentials only reach sandboxes created later.
        case global
        /// Only `sbx` itself on the host, such as registry credentials for
        /// pulling templates and kits.
        case host
        case sandbox(String)

        var sandboxName: String? {
            if case let .sandbox(name) = self { name } else { nil }
        }
    }

    /// Where sbx gets the value.
    enum Source: Hashable {
        /// A value stored when the secret was set.
        case value
        /// A 1Password `op://` reference or AWS Secrets Manager ARN.
        case ref(String)
        /// A command run on the host whose output is the value.
        case command(String)
        case oauth
    }

    let kind: Kind
    /// The service, such as "github", the registry's hostname, or the custom
    /// secret's name.
    let name: String
    let scope: Scope
    var source = Source.value
    /// Such as "gho_GCaw****...****43qy".
    var maskedValue: String?
    /// How often sbx resolves a reference or command again.
    var refresh: String?
    /// The hosts a custom secret is sent to.
    var hosts: [String] = []
    /// The variable a custom secret's placeholder is set in.
    var environmentVariable: String?
    /// What the sandbox sees in place of a custom secret's value.
    var placeholder: String?
    var username: String?
    var authEndpoint: String?

    var id: String {
        let scopeKey = switch scope {
        case .global: "global"
        case .host: "host"
        case let .sandbox(name): "sandbox:\(name)"
        }
        return "\(kind)/\(scopeKey)/\(name)/\(placeholder ?? "")"
    }

    /// The service's name as people write it, such as "GitHub".
    var title: String {
        switch kind {
        case .service: Self.serviceTitle(name)
        case .custom, .registry, .other: name
        }
    }

    var canEdit: Bool {
        switch kind {
        case .service, .registry: true
        case .custom: !hosts.isEmpty
        case .other: false
        }
    }

    /// The services `sbx secret set` accepts.
    static let services = [
        "anthropic", "copilot", "cursor", "devin", "droid", "github", "google",
        "groq", "mistral", "nebius", "openai", "openrouter", "xai",
    ]

    static func serviceTitle(_ service: String) -> String {
        switch service.lowercased() {
        case "anthropic": "Anthropic"
        case "copilot": "GitHub Copilot"
        case "cursor": "Cursor"
        case "devin": "Devin"
        case "droid": "Droid"
        case "github": "GitHub"
        case "google": "Google"
        case "groq": "Groq"
        case "mistral": "Mistral"
        case "nebius": "Nebius"
        case "openai": "OpenAI"
        case "openrouter": "OpenRouter"
        case "xai": "xAI"
        default: service
        }
    }

    static let listArguments = ["secret", "ls", "--json"]

    /// Nil when the app can't tell sbx which secret to remove.
    var removeArguments: [String]? {
        var arguments: [String]
        switch kind {
        case .service:
            arguments = ["secret", "rm", name, "--force"]
        case .custom:
            guard let placeholder else { return nil }
            arguments = ["secret", "rm", "--placeholder", placeholder, "--force"]
        case .registry:
            arguments = ["secret", "rm", "--registry", name, "--force"]
            if scope == .global {
                arguments.append("--all-sandboxes")
            }
        case .other:
            return nil
        }
        if let sandbox = scope.sandboxName {
            arguments += ["--sandbox", sandbox]
        }
        return arguments
    }

    static func fetch() async throws -> [SbxSecret] {
        let output = try await SbxCLI.runChecked(listArguments)
        return try SecretListParser.parse(output)
    }
}

/// A secret being added, or new settings for an existing one.
struct SecretDraft: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case service
        case custom
        case registry

        var id: Self { self }

        var title: String {
            switch self {
            case .service: "Service"
            case .custom: "Custom"
            case .registry: "Registry"
            }
        }
    }

    enum SourceKind: String, CaseIterable, Identifiable {
        case value
        case ref
        case command

        var id: Self { self }

        var title: String {
            switch self {
            case .value: "Value"
            case .ref: "Reference"
            case .command: "Command"
            }
        }
    }

    let id = UUID()
    var kind = Kind.service
    var service = "github"
    var scope = SbxSecret.Scope.global
    var sourceKind = SourceKind.value
    /// The token, API key or registry password.
    var value = ""
    var ref = ""
    var command = ""
    var refresh = ""
    /// Hosts for a custom secret, separated by commas or spaces.
    var hosts = ""
    var environmentVariable = ""
    var placeholder = ""
    var registry = ""
    var username = ""
    var authEndpoint = ""
    /// The secret being edited, which fixes its kind, name and scope.
    private(set) var original: SbxSecret?

    var isEditing: Bool { original != nil }

    init(scope: SbxSecret.Scope = .global) {
        self.scope = scope
    }

    init(editing secret: SbxSecret) {
        original = secret
        scope = secret.scope
        switch secret.kind {
        case .service, .other:
            kind = .service
            service = secret.name
        case .custom:
            kind = .custom
            hosts = secret.hosts.joined(separator: ", ")
            environmentVariable = secret.environmentVariable ?? ""
            placeholder = secret.placeholder ?? ""
        case .registry:
            kind = .registry
            registry = secret.name
            username = secret.username ?? ""
            authEndpoint = secret.authEndpoint ?? ""
        }
        switch secret.source {
        case .value, .oauth:
            sourceKind = .value
        case let .ref(ref):
            sourceKind = .ref
            self.ref = ref
        case let .command(command):
            sourceKind = .command
            self.command = command
        }
        refresh = secret.refresh ?? ""
    }

    var hostList: [String] {
        hosts.split { $0 == "," || $0.isWhitespace }.map(String.init)
    }

    /// Registry credentials always store a password.
    var effectiveSourceKind: SourceKind {
        kind == .registry ? .value : sourceKind
    }

    /// What's missing before it can be saved, or nil when it's ready.
    var missing: String? {
        switch kind {
        case .service:
            break
        case .custom:
            if hostList.isEmpty { return "Enter the hosts to send the secret to." }
        case .registry:
            if trimmed(registry).isEmpty { return "Enter the registry's hostname." }
        }
        switch effectiveSourceKind {
        case .value:
            if trimmed(value).isEmpty { return kind == .registry ? "Enter the password or token." : "Enter the secret's value." }
        case .ref:
            if trimmed(ref).isEmpty { return "Enter a 1Password or AWS Secrets Manager reference." }
        case .command:
            if trimmed(command).isEmpty { return "Enter the command that prints the secret." }
        }
        return nil
    }

    /// The `sbx` arguments that store it, and what to write to standard
    /// input. Values go on standard input where sbx accepts that, so they
    /// don't show in the process's arguments.
    var invocation: (arguments: [String], input: String?) {
        var arguments: [String]
        var input: String?
        switch kind {
        case .service:
            arguments = ["secret", "set", service, "--force"]
        case .custom:
            arguments = ["secret", "set-custom"] + hostList.flatMap { ["--host", $0] }
            if !trimmed(environmentVariable).isEmpty {
                arguments += ["--env", trimmed(environmentVariable)]
            }
            if !trimmed(placeholder).isEmpty {
                arguments += ["--placeholder", trimmed(placeholder)]
            }
        case .registry:
            arguments = ["secret", "set", "--registry", trimmed(registry)]
            if !trimmed(username).isEmpty {
                arguments += ["--username", trimmed(username)]
            }
            if !trimmed(authEndpoint).isEmpty {
                arguments += ["--registry-auth-endpoint", trimmed(authEndpoint)]
            }
            if scope == .global {
                arguments.append("--all-sandboxes")
            }
        }
        if let sandbox = scope.sandboxName {
            arguments += ["--sandbox", sandbox]
        }
        switch effectiveSourceKind {
        case .value:
            switch kind {
            case .service:
                input = trimmed(value)
            case .custom:
                // set-custom only takes the value as an argument.
                arguments += ["--value", trimmed(value)]
            case .registry:
                arguments.append("--password-stdin")
                input = trimmed(value)
            }
        case .ref:
            arguments += ["--ref", trimmed(ref)]
        case .command:
            arguments += ["--command", trimmed(command)]
        }
        if effectiveSourceKind != .value, !trimmed(refresh).isEmpty {
            arguments += ["--refresh", trimmed(refresh)]
        }
        return (arguments, input)
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reads `sbx secret ls --json`, accepting a list of secrets or secrets
/// grouped by scope or kind.
enum SecretListParser {
    struct ParseError: LocalizedError {
        let output: String
        var errorDescription: String? {
            "Couldn't read the output of sbx secret ls --json:\n\(output)"
        }
    }

    static func parse(_ output: String) throws -> [SbxSecret] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" {
            return []
        }
        // Skip any warnings printed before the JSON document.
        guard let start = trimmed.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let data = String(trimmed[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            throw ParseError(output: trimmed)
        }
        var seen = Set<SbxSecret.ID>()
        return secrets(in: json, scope: nil, kind: nil)
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    /// Walks the document, carrying the scope or kind from the key a group
    /// of secrets sits under, such as `"global": [...]`.
    private static func secrets(in json: Any, scope: SbxSecret.Scope?, kind: SbxSecret.Kind?) -> [SbxSecret] {
        if let array = json as? [Any] {
            return array.flatMap { secrets(in: $0, scope: scope, kind: kind) }
        }
        if let name = json as? String, let kind {
            // A list of names under a scope.
            return [SbxSecret(kind: kind, name: name, scope: scope ?? .global)]
        }
        guard let object = json as? [String: Any] else { return [] }
        if let secret = secret(from: object, scope: scope, kind: kind) {
            return [secret]
        }
        return object.flatMap { key, value -> [SbxSecret] in
            switch normalize(key) {
            case "global", "globals":
                return secrets(in: value, scope: .global, kind: kind)
            case "host", "hostonly":
                return secrets(in: value, scope: .host, kind: kind)
            case "registry", "registries", "registrycredentials":
                return secrets(in: value, scope: scope, kind: .registry)
            case "custom", "customs", "customsecrets":
                return secrets(in: value, scope: scope, kind: .custom)
            case "service", "services", "servicesecrets":
                return secrets(in: value, scope: scope, kind: .service)
            case "sandbox", "sandboxes":
                // Either a map of sandbox name to its secrets, or records
                // that name their sandbox.
                if let bySandbox = value as? [String: Any], !looksLikeRecord(bySandbox) {
                    return bySandbox.flatMap { name, nested in
                        secrets(in: nested, scope: .sandbox(name), kind: kind)
                    }
                }
                return secrets(in: value, scope: scope, kind: kind)
            case "secrets", "items", "data", "results":
                return secrets(in: value, scope: scope, kind: kind)
            default:
                // A map of service name to details.
                if var record = value as? [String: Any], field(record, ["service", "name"]) == nil {
                    record["service"] = key
                    return secret(from: record, scope: scope, kind: kind).map { [$0] } ?? []
                }
                return []
            }
        }
    }

    private static func looksLikeRecord(_ object: [String: Any]) -> Bool {
        field(object, ["service", "registry", "name", "placeholder", "scope"]) != nil
    }

    private static func secret(from record: [String: Any], scope inherited: SbxSecret.Scope?, kind inheritedKind: SbxSecret.Kind?) -> SbxSecret? {
        let typeName = text(record, ["type", "kind", "secret_type", "category"])?.lowercased()
        let registry = text(record, ["registry", "registry_host", "hostname"])
        let hosts = list(field(record, ["hosts", "host_patterns", "domains", "allowed_hosts"]))
        let placeholder = text(record, ["placeholder", "placeholder_value"])
        let kind: SbxSecret.Kind
        if registry != nil || typeName?.contains("registry") == true || inheritedKind == .registry {
            kind = .registry
        } else if typeName?.contains("custom") == true || placeholder != nil || !hosts.isEmpty || inheritedKind == .custom {
            kind = .custom
        } else if let typeName, typeName.contains("mcp") {
            kind = .other(typeName)
        } else {
            kind = inheritedKind ?? .service
        }
        let name: String? = switch kind {
        case .registry: registry ?? text(record, ["host", "name"])
        case .custom: text(record, ["name", "id", "service"]) ?? hosts.first ?? placeholder
        case .service, .other: text(record, ["service", "name", "id"])
        }
        guard let name, !name.isEmpty else { return nil }
        return SbxSecret(
            kind: kind,
            name: name,
            scope: scope(from: record) ?? inherited ?? (kind == .registry ? .host : .global),
            source: source(from: record),
            maskedValue: text(record, ["secret", "masked", "masked_value", "masked_secret", "value", "token", "preview"]),
            refresh: text(record, ["refresh", "refresh_policy", "refresh_interval"]),
            hosts: hosts,
            environmentVariable: text(record, ["env", "env_var", "env_name", "environment_variable", "envvar"]),
            placeholder: placeholder,
            username: text(record, ["username", "user"]),
            authEndpoint: text(record, ["registry_auth_endpoint", "auth_endpoint"])
        )
    }

    private static func source(from record: [String: Any]) -> SbxSecret.Source {
        if let ref = text(record, ["ref", "reference", "secret_ref", "source_ref"]) {
            return .ref(ref)
        }
        if let command = text(record, ["command", "cmd", "source_command"]) {
            return .command(command)
        }
        let value = field(record, ["source", "method", "auth", "auth_type", "provider", "origin"])
        if let nested = value as? [String: Any] {
            return source(from: nested)
        }
        guard let description = SandboxListParser.string(value)?.trimmingCharacters(in: .whitespaces) else {
            return .value
        }
        let lowered = description.lowercased()
        if lowered.hasPrefix("op://") || lowered.hasPrefix("arn:") {
            return .ref(description)
        }
        if lowered.contains("oauth") {
            return .oauth
        }
        return .value
    }

    private static func scope(from record: [String: Any]) -> SbxSecret.Scope? {
        if let sandbox = text(record, ["sandbox", "sandbox_name"]) {
            return .sandbox(sandbox)
        }
        if let allSandboxes = field(record, ["all_sandboxes"]) as? Bool {
            return allSandboxes ? .global : .host
        }
        guard let scope = text(record, ["scope"]) else { return nil }
        switch normalize(scope.trimmingCharacters(in: CharacterSet(charactersIn: "()"))) {
        case "global", "all", "allsandboxes": return .global
        case "host", "hostonly": return .host
        default:
            // Such as "sandbox:my-sandbox", or just the sandbox's name.
            if let colon = scope.firstIndex(of: ":") {
                return .sandbox(String(scope[scope.index(after: colon)...]))
            }
            return .sandbox(scope)
        }
    }

    private static func field(_ record: [String: Any], _ keys: [String]) -> Any? {
        SandboxListParser.value(in: record, for: keys)
    }

    /// A non-empty string for the first of `keys` the record has.
    private static func text(_ record: [String: Any], _ keys: [String]) -> String? {
        guard let string = SandboxListParser.string(field(record, keys))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty
        else {
            return nil
        }
        return string
    }

    private static func list(_ value: Any?) -> [String] {
        if let array = value as? [Any] {
            return array.compactMap { SandboxListParser.string($0) }.filter { !$0.isEmpty }
        }
        guard let string = value as? String else { return [] }
        return string.split { $0 == "," || $0.isWhitespace }.map(String.init)
    }

    private static func normalize(_ key: String) -> String {
        key.lowercased().filter { $0 != "_" && $0 != "-" && $0 != " " }
    }
}
