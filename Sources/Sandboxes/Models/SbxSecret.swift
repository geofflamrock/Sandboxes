import Foundation

/// A secret stored by sbx: an API key or token for a service, or pull
/// credentials for a container registry. sbx never shows a secret's value.
struct SbxSecret: Identifiable, Hashable {
    enum Kind: Hashable {
        case service
        case registry
    }

    enum Scope: Hashable {
        /// Every sandbox created from now on.
        case global
        /// Only `sbx` itself on the host, such as registry credentials for
        /// pulling templates and kits.
        case host
        case sandbox(String)

        var sandboxName: String? {
            if case let .sandbox(name) = self { name } else { nil }
        }
    }

    let kind: Kind
    /// The service, such as "github", or the registry's hostname.
    let name: String
    let scope: Scope
    /// Where the value comes from when sbx says, such as a 1Password
    /// reference or OAuth.
    let source: String?

    var id: String {
        let scopeKey = switch scope {
        case .global: "global"
        case .host: "host"
        case let .sandbox(name): "sandbox:\(name)"
        }
        return "\(kind)/\(scopeKey)/\(name)"
    }

    /// The service's name as people write it, such as "GitHub".
    var title: String {
        switch kind {
        case .service: Self.serviceTitle(name)
        case .registry: name
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

    /// Stores `service`'s secret, replacing any it already has in that scope.
    /// The value is passed on standard input so it doesn't show in the
    /// process's arguments.
    static func setArguments(service: String, sandbox: String?) -> [String] {
        var arguments = ["secret", "set", service, "--force"]
        if let sandbox {
            arguments += ["--sandbox", sandbox]
        }
        return arguments
    }

    var removeArguments: [String] {
        switch kind {
        case .service:
            var arguments = ["secret", "rm", name, "--force"]
            if let sandbox = scope.sandboxName {
                arguments += ["--sandbox", sandbox]
            }
            return arguments
        case .registry:
            var arguments = ["secret", "rm", "--registry", name, "--force"]
            switch scope {
            case .global: arguments.append("--all-sandboxes")
            case let .sandbox(sandbox): arguments += ["--sandbox", sandbox]
            case .host: break
            }
            return arguments
        }
    }

    static func fetch() async throws -> [SbxSecret] {
        let output = try await SbxCLI.runChecked(listArguments)
        return try SecretListParser.parse(output)
    }
}

/// Reads `sbx secret ls --json`, accepting a list of secrets or secrets
/// grouped by scope.
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
            return [SbxSecret(kind: kind, name: name, scope: scope ?? .global, source: nil)]
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
                if var record = value as? [String: Any], SandboxListParser.value(in: record, for: nameKeys) == nil {
                    record["service"] = key
                    return secret(from: record, scope: scope, kind: kind).map { [$0] } ?? []
                }
                return []
            }
        }
    }

    private static let nameKeys = ["service", "registry", "name", "host", "hostname"]

    private static func looksLikeRecord(_ object: [String: Any]) -> Bool {
        SandboxListParser.value(in: object, for: nameKeys + ["scope"]) != nil
    }

    private static func secret(from record: [String: Any], scope inherited: SbxSecret.Scope?, kind inheritedKind: SbxSecret.Kind?) -> SbxSecret? {
        let typeName = SandboxListParser.string(SandboxListParser.value(in: record, for: ["type", "kind"]))?.lowercased()
        let registry = SandboxListParser.string(SandboxListParser.value(in: record, for: ["registry", "registry_host", "hostname"]))
        let kind: SbxSecret.Kind = if registry != nil || typeName?.contains("registry") == true {
            .registry
        } else {
            inheritedKind ?? .service
        }
        let nameKeys = kind == .registry
            ? ["registry", "registry_host", "hostname", "host", "name"]
            : ["service", "name", "id"]
        guard let name = SandboxListParser.string(SandboxListParser.value(in: record, for: nameKeys)), !name.isEmpty else {
            return nil
        }
        return SbxSecret(
            kind: kind,
            name: name,
            scope: scope(from: record) ?? inherited ?? .global,
            source: SandboxListParser.string(SandboxListParser.value(in: record, for: ["source", "method", "auth", "auth_type", "provider"]))
        )
    }

    private static func scope(from record: [String: Any]) -> SbxSecret.Scope? {
        if let sandbox = SandboxListParser.string(SandboxListParser.value(in: record, for: ["sandbox", "sandbox_name"])),
           !sandbox.isEmpty {
            return .sandbox(sandbox)
        }
        if let allSandboxes = SandboxListParser.value(in: record, for: ["all_sandboxes"]) as? Bool {
            return allSandboxes ? .global : .host
        }
        guard let scope = SandboxListParser.string(SandboxListParser.value(in: record, for: ["scope"]))?
            .trimmingCharacters(in: .whitespaces), !scope.isEmpty
        else {
            return nil
        }
        switch normalize(scope) {
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

    private static func normalize(_ key: String) -> String {
        key.lowercased().filter { $0 != "_" && $0 != "-" && $0 != " " }
    }
}
