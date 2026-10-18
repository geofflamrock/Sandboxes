import Foundation

/// A server registered with `sbx mcp add`. Registrations belong to the host,
/// and any sandbox can load one. sbx doesn't report which sandboxes have.
struct MCPServer: Identifiable, Hashable {
    enum Transport: Hashable {
        /// A remote endpoint the sandbox's gateway connects to over HTTP.
        case remote
        /// A command, or a container from a registry, run on the Mac outside
        /// the sandbox.
        case local
        case other(String)
    }

    enum Status: Hashable {
        case ready
        case needsAuthorisation
        /// A `${placeholder}` in a header has no stored value.
        case needsSecret
        /// sbx's own word for anything else, such as headers the gateway
        /// can't send.
        case other(String)
    }

    /// Where the server runs and who controls it, from `sbx mcp ls`.
    struct Gateway: Hashable {
        /// Such as "LOCAL".
        var name: String
        /// Unloading and custom headers only work with a local gateway.
        var isLocal: Bool
        /// Such as "managed by you".
        var operatedBy: String?
        var signedInAs: String?

        /// Such as "LOCAL, managed by you", as `sbx mcp ls` writes it.
        var summary: String {
            ([name] + [operatedBy].compactMap { $0 }).joined(separator: ", ")
        }
    }

    let name: String
    var transport: Transport
    /// sbx's wording, such as "remote http".
    var transportLabel: String?
    var status: Status
    /// Such as "1 header secret not set" or "custom headers".
    var detail: String?
    /// The command sbx suggests running next, such as `sbx mcp auth linear`.
    var nextStep: String?
    var gateway: Gateway?

    var id: String { name }

    var transportTitle: String {
        switch transport {
        case .remote: "Remote"
        case .local: "Runs on this Mac"
        case let .other(type): transportLabel ?? type
        }
    }

    var statusTitle: String {
        switch status {
        case .ready: "Ready"
        case .needsAuthorisation: "Needs Authorisation"
        case .needsSecret: "Needs a Secret"
        case let .other(status): status.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    /// Unloading needs a local gateway: hosted gateways don't support it.
    var canUnload: Bool {
        gateway?.isLocal ?? true
    }

    static let listArguments = ["mcp", "ls", "--json"]

    var inspectArguments: [String] { ["mcp", "inspect", name, "--json"] }
    /// Without `--force`, sbx refuses to run when its input isn't a terminal.
    var removeArguments: [String] { ["mcp", "rm", name, "--force"] }
    var removeCredentialsArguments: [String] { ["mcp", "auth", "rm", name, "--force"] }

    func loadArguments(into sandbox: String) -> [String] {
        ["mcp", "load", name, "--sandbox", sandbox]
    }

    func unloadArguments(from sandbox: String) -> [String] {
        ["mcp", "unload", name, "--sandbox", sandbox]
    }

    static func fetch() async throws -> [MCPServer] {
        let output = try await SbxCLI.runChecked(listArguments)
        return try MCPServerListParser.parse(output)
    }
}

/// What `sbx mcp inspect` reports about a server: where it is or what it
/// runs, and its headers and their secrets. Values are never included.
struct MCPServerDetails: Hashable {
    struct Header: Hashable {
        let name: String
        /// As registered, with `${placeholder}`s.
        let value: String
    }

    struct HeaderSecret: Hashable, Identifiable {
        let placeholder: String
        let isStored: Bool

        var id: String { placeholder }
    }

    let name: String
    var url: String?
    /// Such as "streamable-http".
    var remoteTransport: String?
    var requiresOAuth = false
    /// Each OAuth provider's issuer, such as "https://mcp.linear.app".
    var oauthIssuers: [String] = []
    var headers: [Header] = []
    var headerSecrets: [HeaderSecret] = []
    /// The executable, then its arguments.
    var command: [String] = []
    /// The executable's full path, such as `/opt/homebrew/bin/npx`.
    var resolvedCommand: String?
    /// Anything else sbx reported, so nothing is hidden.
    var otherFields: [String: String] = [:]

    static func fetch(for server: MCPServer) async throws -> MCPServerDetails {
        let output = try await SbxCLI.runChecked(server.inspectArguments)
        return try MCPServerDetailsParser.parse(output, name: server.name)
    }

    /// The name `sbx secret set` stores a header placeholder's value under.
    static func secretName(server: String, placeholder: String) -> String {
        "mcp:\(server):\(placeholder)"
    }
}

/// A server being added with `sbx mcp add`.
struct MCPServerDraft {
    enum Source: CaseIterable, Identifiable {
        /// A remote endpoint, a registry or manifest URL, or a `dhi.io`
        /// image. sbx works out which.
        case url
        /// A command run on the Mac.
        case command

        var id: Self { self }

        var title: String {
            switch self {
            case .url: "URL"
            case .command: "Command"
            }
        }
    }

    struct Header: Identifiable {
        let id = UUID()
        var name = ""
        var value = ""

        var isBlank: Bool {
            name.trimmingCharacters(in: .whitespaces).isEmpty && value.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var name = ""
    var source = Source.url
    var url = ""
    /// Runs a registry or manifest server on the Mac with `docker run`.
    var runsLocally = false
    var headers: [Header] = []
    /// Values for the headers' `${placeholder}`s, keyed by placeholder. sbx
    /// only registers a server once each one has a stored secret.
    var headerSecretValues: [String: String] = [:]
    var clientID = ""
    /// Separated by commas or spaces.
    var scopes = ""
    var skipsSSRFCheck = false
    var command = ""
    /// One argument per line.
    var argumentsText = ""
    var directory: URL?

    var trimmedName: String { trimmed(name) }

    var argumentList: [String] {
        argumentsText.split(whereSeparator: \.isNewline)
            .map { trimmed(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// The `${placeholder}`s in the headers, in the order they first appear.
    var placeholders: [String] {
        guard source == .url else { return [] }
        var seen = Set<String>()
        return headers.flatMap { header in
            header.value.matches(of: #/\$\{([^}\s]+)\}/#).map { String($0.1) }
        }
        .filter { seen.insert($0).inserted }
    }

    /// The values entered for current placeholders, trimmed.
    var headerSecretsToSet: [String: String] {
        var values: [String: String] = [:]
        for placeholder in placeholders {
            let value = trimmed(headerSecretValues[placeholder] ?? "")
            if !value.isEmpty {
                values[placeholder] = value
            }
        }
        return values
    }

    /// Asks for a value for each placeholder that doesn't already have a
    /// stored secret, such as from when a server of the same name was removed.
    func missingSecret(stored: Set<String>) -> String? {
        let needed = placeholders.filter {
            !stored.contains($0) && trimmed(headerSecretValues[$0] ?? "").isEmpty
        }
        guard let first = needed.first else { return nil }
        return "Enter a value for ${\(first)}."
    }

    var scopeList: [String] {
        scopes.split { $0 == "," || $0.isWhitespace }.map(String.init)
    }

    /// What's missing before it can be added, or nil when it's ready.
    var missing: String? {
        if trimmedName.isEmpty {
            return "Enter a name for the server."
        }
        if trimmedName.wholeMatch(of: #/[A-Za-z0-9._\-]+/#) == nil {
            return "Names can only contain letters, numbers, dots, hyphens and underscores."
        }
        switch source {
        case .url:
            if trimmed(url).isEmpty { return "Enter the server's URL." }
            let named = headers.filter { !$0.isBlank }
            if named.contains(where: { trimmed($0.name).isEmpty }) {
                return "Enter a name for each header."
            }
            let names = named.map { trimmed($0.name).lowercased() }
            if Set(names).count != names.count {
                return "Each header can only be given once."
            }
        case .command:
            if trimmed(command).isEmpty { return "Enter the command that starts the server." }
        }
        return nil
    }

    var addArguments: [String] {
        var arguments = ["mcp", "add", trimmedName]
        switch source {
        case .url:
            arguments += ["--url", trimmed(url)]
            if runsLocally {
                arguments.append("--local")
            }
            for header in headers where !header.isBlank {
                arguments += ["--header", "\(trimmed(header.name)): \(trimmed(header.value))"]
            }
            if !trimmed(clientID).isEmpty {
                arguments += ["--client-id", trimmed(clientID)]
            }
            for scope in scopeList {
                arguments += ["--scope", scope]
            }
            if skipsSSRFCheck {
                arguments.append("--skip-ssrf-check")
            }
            // The app authorises separately, so adding never waits on a browser.
            arguments.append("--skip-auth")
        case .command:
            arguments += ["--command", trimmed(command)]
            for argument in argumentList {
                arguments += ["--args", Self.csvQuoted(argument)]
            }
            if let directory {
                arguments += ["--dir", directory.path]
            }
        }
        return arguments
    }

    var commandLine: String {
        (["sbx"] + addArguments).map(Self.quoteIfNeeded).joined(separator: " ")
    }

    /// sbx splits each `--args` value on commas, reading it as CSV, so an
    /// argument with a comma or quote is quoted to keep it whole.
    static func csvQuoted(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:@=+,~"))
        if !value.isEmpty && value.unicodeScalars.allSatisfy(safe.contains) {
            return value
        }
        return TerminalLauncher.shellQuote(value)
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reads `sbx mcp ls --json`: a list of servers, each with a name, type,
/// transport, status, optional detail and next step, and its gateway.
enum MCPServerListParser {
    struct ParseError: LocalizedError {
        let output: String
        var errorDescription: String? {
            "Couldn't read the output of sbx mcp ls --json:\n\(output)"
        }
    }

    static func parse(_ output: String) throws -> [MCPServer] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" {
            return []
        }
        guard let json = MCPJSON.document(in: trimmed) else {
            throw ParseError(output: trimmed)
        }
        var seen = Set<String>()
        return records(in: json)
            .compactMap(server(from:))
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A list of servers, servers under a key such as `servers`, or a map
    /// of name to server.
    private static func records(in json: Any) -> [[String: Any]] {
        if let array = json as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        guard let object = json as? [String: Any] else { return [] }
        if MCPJSON.text(object, ["name"]) != nil {
            return [object]
        }
        if let nested = MCPJSON.field(object, ["servers", "items", "data", "results"]) {
            return records(in: nested)
        }
        return object.compactMap { key, value -> [String: Any]? in
            guard var record = value as? [String: Any] else { return nil }
            record["name"] = record["name"] ?? key
            return record
        }
    }

    private static func server(from record: [String: Any]) -> MCPServer? {
        guard let name = MCPJSON.text(record, ["name", "id"]) else { return nil }
        let transportLabel = MCPJSON.text(record, ["transport"])
        return MCPServer(
            name: name,
            transport: transport(type: MCPJSON.text(record, ["type", "kind"]), label: transportLabel),
            transportLabel: transportLabel,
            status: status(MCPJSON.text(record, ["status", "state"])),
            detail: MCPJSON.text(record, ["detail", "details", "message"]),
            nextStep: MCPJSON.text(record, ["next_step", "nextStep", "hint"]),
            gateway: gateway(MCPJSON.field(record, ["gateway"]))
        )
    }

    private static func transport(type: String?, label: String?) -> MCPServer.Transport {
        let text = (type ?? label ?? "").lowercased()
        if text.contains("remote") || text.contains("http") {
            return .remote
        }
        if text.contains("local") || text.contains("stdio") {
            return .local
        }
        return .other(type ?? label ?? "Unknown")
    }

    /// Seen as `ready`, `needs-auth` and `needs-secret`.
    private static func status(_ text: String?) -> MCPServer.Status {
        guard let text else { return .other("unknown") }
        let lowered = text.lowercased()
        if lowered == "ready" || lowered == "usable" || lowered == "ok" {
            return .ready
        }
        if lowered.contains("auth") {
            return .needsAuthorisation
        }
        if lowered.contains("secret") {
            return .needsSecret
        }
        return .other(text)
    }

    /// An object, as v0.48.0 reports it, or the table's "LOCAL, managed by you".
    private static func gateway(_ value: Any?) -> MCPServer.Gateway? {
        if let object = value as? [String: Any] {
            guard let name = MCPJSON.text(object, ["name"]) else { return nil }
            return MCPServer.Gateway(
                name: name,
                isLocal: MCPJSON.bool(object, ["local", "is_local"]) ?? (name.lowercased() == "local"),
                operatedBy: MCPJSON.text(object, ["operator", "managed_by"]),
                signedInAs: MCPJSON.text(object, ["signed_in_as", "user", "identity"])
            )
        }
        guard let text = SandboxListParser.string(value), !text.isEmpty else { return nil }
        let parts = text.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return MCPServer.Gateway(
            name: parts[0],
            isLocal: parts[0].lowercased() == "local",
            operatedBy: parts.count > 1 ? parts[1] : nil
        )
    }
}

/// Reads `sbx mcp inspect NAME --json`.
enum MCPServerDetailsParser {
    struct ParseError: LocalizedError {
        let output: String
        var errorDescription: String? {
            "Couldn't read the output of sbx mcp inspect --json:\n\(output)"
        }
    }

    /// Keys shown in their own rows, so they aren't repeated in `otherFields`.
    private static let knownKeys: Set<String> = [
        "name", "type", "url", "remotetransport", "requiresoauth", "oauthproviders",
        "headers", "headersecrets", "command", "resolvedcommand",
    ]

    static func parse(_ output: String, name: String) throws -> MCPServerDetails {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = MCPJSON.document(in: trimmed) else {
            throw ParseError(output: trimmed)
        }
        var record = json as? [String: Any]
        if record == nil, let array = json as? [Any] {
            record = array.compactMap { $0 as? [String: Any] }.first
        }
        guard let record else { throw ParseError(output: trimmed) }

        var details = MCPServerDetails(name: MCPJSON.text(record, ["name"]) ?? name)
        details.url = MCPJSON.text(record, ["url", "endpoint"])
        details.remoteTransport = MCPJSON.text(record, ["remote_transport", "transport"])
        details.requiresOAuth = MCPJSON.bool(record, ["requires_oauth", "oauth"]) ?? false
        details.oauthIssuers = (MCPJSON.field(record, ["oauth_providers"]) as? [Any] ?? []).compactMap { provider -> String? in
            guard let provider = provider as? [String: Any] else { return SandboxListParser.string(provider) }
            return MCPJSON.text(provider, ["issuer", "authorization_server", "url"])
        }
        details.headers = headers(MCPJSON.field(record, ["headers"]))
        details.headerSecrets = (MCPJSON.field(record, ["header_secrets"]) as? [Any] ?? []).compactMap { secret -> MCPServerDetails.HeaderSecret? in
            guard let secret = secret as? [String: Any],
                  let placeholder = MCPJSON.text(secret, ["placeholder", "name"])
            else { return nil }
            return MCPServerDetails.HeaderSecret(placeholder: placeholder, isStored: MCPJSON.bool(secret, ["stored", "set"]) ?? false)
        }
        if let command = MCPJSON.field(record, ["command"]) as? [Any] {
            details.command = command.compactMap { SandboxListParser.string($0) }
        } else if let command = MCPJSON.text(record, ["command"]) {
            let arguments = (MCPJSON.field(record, ["args"]) as? [Any])?.compactMap { SandboxListParser.string($0) } ?? []
            details.command = [command] + arguments
        }
        details.resolvedCommand = MCPJSON.text(record, ["resolved_command"])
        for (key, value) in record where !knownKeys.contains(MCPJSON.normalize(key)) {
            if let text = SandboxListParser.string(value), !text.isEmpty {
                details.otherFields[key] = text
            } else if JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                details.otherFields[key] = String(decoding: data, as: UTF8.self)
            }
        }
        return details
    }

    /// A list of `{ name, value }`, or a map of name to value.
    private static func headers(_ value: Any?) -> [MCPServerDetails.Header] {
        if let map = value as? [String: Any] {
            return map.compactMap { name, value in
                SandboxListParser.string(value).map { MCPServerDetails.Header(name: name, value: $0) }
            }
            .sorted { $0.name < $1.name }
        }
        return (value as? [Any] ?? []).compactMap { header -> MCPServerDetails.Header? in
            if let header = header as? [String: Any], let name = MCPJSON.text(header, ["name"]) {
                return MCPServerDetails.Header(name: name, value: MCPJSON.text(header, ["value"]) ?? "")
            }
            // "Name: value", as passed to --header.
            guard let line = SandboxListParser.string(header), let colon = line.firstIndex(of: ":") else { return nil }
            return MCPServerDetails.Header(
                name: String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                value: String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            )
        }
    }
}

/// Helpers shared by the MCP parsers.
private enum MCPJSON {
    /// The JSON document in `text`, skipping any warnings printed before it.
    static func document(in text: String) -> Any? {
        guard let start = text.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let data = String(text[start...]).data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func field(_ record: [String: Any], _ keys: [String]) -> Any? {
        SandboxListParser.value(in: record, for: keys)
    }

    /// A non-empty string for the first of `keys` the record has.
    static func text(_ record: [String: Any], _ keys: [String]) -> String? {
        guard let string = SandboxListParser.string(field(record, keys))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty
        else { return nil }
        return string
    }

    static func bool(_ record: [String: Any], _ keys: [String]) -> Bool? {
        switch field(record, keys) {
        case let bool as Bool: bool
        case let number as NSNumber: number.boolValue
        case let string as String: ["true", "yes", "1"].contains(string.lowercased())
        default: nil
        }
    }

    static func normalize(_ key: String) -> String {
        key.lowercased().filter { $0 != "_" && $0 != "-" }
    }
}
