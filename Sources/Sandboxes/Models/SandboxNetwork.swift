import Foundation

enum NetworkDecision: Hashable {
    case allow
    case deny

    /// Reads decisions such as `allow`, `deny`, `blocked` or `POLICY_DECISION_ALLOWED`.
    init?(_ text: String?) {
        guard let text = text?.lowercased() else { return nil }
        if text.contains("deny") || text.contains("block") {
            self = .deny
        } else if text.contains("allow") {
            self = .allow
        } else {
            return nil
        }
    }
}

/// A network rule that applies to a sandbox, from `sbx policy ls`.
struct NetworkRule: Identifiable, Hashable {
    let id: String
    let decision: NetworkDecision
    let resources: [String]
    /// Where the rule came from: `local`, `kit` or `org`.
    let source: String?
    /// `all` for a global rule, or `sandbox:NAME` for one scoped to a sandbox.
    let appliesTo: String?
    let method: String?
    let path: String?
}

/// Requests from a sandbox to one host with the same outcome, from `sbx policy log`.
struct NetworkLogEntry: Identifiable, Hashable {
    var id: String { "\(decision)|\(host)" }
    let host: String
    let decision: NetworkDecision
    let count: Int
    let lastSeen: Date?
}

struct SandboxNetwork: Hashable {
    /// The global preset: `allow-all`, `balanced` or `deny-all`, if `sbx` reports it.
    var preset: String?
    var rules: [NetworkRule]
    /// Most recent first.
    var log: [NetworkLogEntry]

    /// What happens to a request that no rule matches. The Open preset is a
    /// wildcard allow rule, so look for one when the preset isn't reported.
    var defaultDecision: NetworkDecision {
        if let preset = preset?.lowercased() {
            return preset.contains("allow") || preset.contains("open") ? .allow : .deny
        }
        let allowsEverything = rules.contains { rule in
            rule.decision == .allow && rule.method == nil && rule.resources.contains { ["*", "**"].contains($0) }
        }
        return allowsEverything ? .allow : .deny
    }

    var presetLabel: String? {
        switch preset?.lowercased() {
        case nil: nil
        case "allow-all", "open": "Open"
        case "balanced": "Balanced"
        case "deny-all", "locked-down", "locked down": "Locked Down"
        case let other?: other.capitalized
        }
    }

    static func fetch(for sandbox: Sandbox) async throws -> SandboxNetwork {
        async let rulesOutput = SbxCLI.runChecked(["policy", "ls", sandbox.name, "--type", "network", "--json"])
        async let logOutput = SbxCLI.runChecked(["policy", "log", sandbox.name, "--type", "network", "--json"])
        let rulesJSON = try NetworkPolicyParser.document(try await rulesOutput)
        let logJSON = try NetworkPolicyParser.document(try await logOutput)
        return SandboxNetwork(
            preset: NetworkPolicyParser.preset(in: rulesJSON),
            rules: NetworkPolicyParser.rules(in: rulesJSON),
            log: NetworkPolicyParser.log(in: logJSON, sandbox: sandbox.name)
        )
    }
}

/// Parses `sbx policy ls --json` and `sbx policy log --json`. Like `sbx ls`, the
/// schema isn't documented, so this looks for rule- and entry-shaped objects
/// anywhere in the document rather than decoding a fixed model.
enum NetworkPolicyParser {
    typealias JSON = SandboxListParser

    struct ParseError: LocalizedError {
        let output: String
        var errorDescription: String? {
            "Couldn't read the output of sbx policy:\n\(output)"
        }
    }

    static func document(_ output: String) throws -> Any {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" {
            return [Any]()
        }
        // Skip any warnings printed before the JSON document.
        guard let start = trimmed.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let data = String(trimmed[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            throw ParseError(output: trimmed)
        }
        return json
    }

    static func preset(in json: Any) -> String? {
        if let object = json as? [String: Any] {
            if let preset = JSON.string(JSON.value(in: object, for: ["local_preset", "preset"])), !preset.isEmpty {
                return preset
            }
            return object.values.lazy.compactMap { preset(in: $0) }.first
        }
        if let array = json as? [Any] {
            return array.lazy.compactMap { preset(in: $0) }.first
        }
        return nil
    }

    // MARK: Rules

    /// Active network rules, deny rules first.
    static func rules(in json: Any) -> [NetworkRule] {
        var rules: [NetworkRule] = []
        collectRules(in: json, inherited: [:], into: &rules)
        var seen = Set<String>()
        return rules
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.decision != rhs.decision { return lhs.decision == .deny }
                let left = lhs.resources.first ?? "", right = rhs.resources.first ?? ""
                return left.localizedStandardCompare(right) == .orderedAscending
            }
    }

    /// Keys a policy passes down to the rules it contains.
    private static let inheritedKeys = ["source", "applies_to", "scope", "status", "type", "resource_type"]

    private static func collectRules(in json: Any, inherited: [String: Any], into rules: inout [NetworkRule]) {
        if let array = json as? [Any] {
            for item in array {
                collectRules(in: item, inherited: inherited, into: &rules)
            }
            return
        }
        guard let object = json as? [String: Any] else { return }
        var context = inherited
        for key in inheritedKeys {
            if let value = JSON.value(in: object, for: [key]), !(value is [Any]) {
                context[key] = value
            }
        }
        if let rule = rule(from: object, context: context) {
            rules.append(rule)
            return
        }
        for value in object.values where value is [Any] || value is [String: Any] {
            collectRules(in: value, inherited: context, into: &rules)
        }
    }

    private static func rule(from object: [String: Any], context: [String: Any]) -> NetworkRule? {
        guard let decision = decision(of: object) else { return nil }
        let resources = resourceList(JSON.value(in: object, for: ["resources", "resource", "hosts", "host", "domains", "destination"]))
        guard !resources.isEmpty else { return nil }

        let type = JSON.string(JSON.value(in: context, for: ["type", "resource_type"]))?.lowercased() ?? ""
        let status = JSON.string(JSON.value(in: context, for: ["status"]))?.lowercased() ?? ""
        guard !type.contains("filesystem"), status != "inactive" else { return nil }

        let method = JSON.string(JSON.value(in: object, for: ["method", "methods"])).flatMap { $0.isEmpty || $0 == "-" ? nil : $0 }
        let path = JSON.string(JSON.value(in: object, for: ["path"])).flatMap { $0.isEmpty || $0 == "-" ? nil : $0 }
        let appliesTo = scope(JSON.value(in: context, for: ["applies_to", "scope"]))
        let fallbackID = ([decision == .allow ? "allow" : "deny", appliesTo ?? "", method ?? "", path ?? ""] + resources).joined(separator: "|")
        return NetworkRule(
            id: JSON.string(JSON.value(in: object, for: ["rule_id", "id"])) ?? fallbackID,
            decision: decision,
            resources: resources,
            source: JSON.string(JSON.value(in: context, for: ["source"])),
            appliesTo: appliesTo,
            method: method,
            path: path
        )
    }

    /// Reads a decision from a string such as `"allow"`, or an action object
    /// such as `{"allow": {...}}`.
    private static func decision(of object: [String: Any]) -> NetworkDecision? {
        let value = JSON.value(in: object, for: ["decision", "action", "effect", "rule_decision"])
        if let text = value as? String {
            return NetworkDecision(text)
        }
        if let action = value as? [String: Any] {
            return JSON.string(JSON.value(in: action, for: ["type", "decision"])).flatMap { NetworkDecision($0) }
                ?? action.keys.lazy.compactMap { NetworkDecision($0) }.first
        }
        return nil
    }

    private static func resourceList(_ value: Any?) -> [String] {
        let items = value as? [Any] ?? value.map { [$0] } ?? []
        return items.compactMap { item -> String? in
            if let object = item as? [String: Any] {
                return JSON.string(JSON.value(in: object, for: ["value", "resource_value", "resource", "host", "domain", "pattern", "name"]))
            }
            return JSON.string(item)
        }
        .filter { !$0.isEmpty }
    }

    /// Accepts `"all"`, `"sandbox:NAME"`, or an object such as `{"sandbox": "NAME"}`.
    private static func scope(_ value: Any?) -> String? {
        if let object = value as? [String: Any] {
            if let sandbox = JSON.string(JSON.value(in: object, for: ["sandbox", "sandbox_name", "name"])), !sandbox.isEmpty {
                return "sandbox:\(sandbox)"
            }
            return JSON.string(JSON.value(in: object, for: ["type", "kind", "scope"]))
        }
        return JSON.string(value)
    }

    // MARK: Log

    /// One entry per host and outcome, most recent first.
    static func log(in json: Any, sandbox: String) -> [NetworkLogEntry] {
        var entries: [NetworkLogEntry] = []
        collectLog(in: json, decision: nil, sandbox: sandbox, into: &entries)

        var merged: [String: NetworkLogEntry] = [:]
        for entry in entries {
            guard let existing = merged[entry.id] else {
                merged[entry.id] = entry
                continue
            }
            let lastSeen = [existing.lastSeen, entry.lastSeen].compactMap { $0 }.max()
            merged[entry.id] = NetworkLogEntry(host: entry.host, decision: entry.decision, count: existing.count + entry.count, lastSeen: lastSeen)
        }
        return merged.values.sorted { lhs, rhs in
            switch (lhs.lastSeen, rhs.lastSeen) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.host.localizedStandardCompare(rhs.host) == .orderedAscending
            }
        }
    }

    private static func collectLog(in json: Any, decision: NetworkDecision?, sandbox: String, into entries: inout [NetworkLogEntry]) {
        if let array = json as? [Any] {
            for item in array {
                collectLog(in: item, decision: decision, sandbox: sandbox, into: &entries)
            }
            return
        }
        guard let object = json as? [String: Any] else { return }
        if let entry = logEntry(from: object, decision: decision, sandbox: sandbox) {
            entries.append(entry)
            return
        }
        for (key, value) in object where value is [Any] || value is [String: Any] {
            // Groups such as `blocked_hosts` and `allowed_hosts` give the outcome.
            collectLog(in: value, decision: NetworkDecision(key) ?? decision, sandbox: sandbox, into: &entries)
        }
    }

    private static func logEntry(from object: [String: Any], decision inherited: NetworkDecision?, sandbox: String) -> NetworkLogEntry? {
        guard let host = JSON.string(JSON.value(in: object, for: ["host", "hostname", "resource", "destination"])), !host.isEmpty,
              JSON.value(in: object, for: ["count", "last_seen", "lastSeen"]) != nil
        else {
            return nil
        }
        if let entrySandbox = JSON.string(JSON.value(in: object, for: ["sandbox", "sandbox_name", "vm_name"])),
           !entrySandbox.isEmpty, entrySandbox != sandbox {
            return nil
        }
        guard let decision = entryDecision(object) ?? inherited else { return nil }
        return NetworkLogEntry(
            host: host,
            decision: decision,
            count: JSON.number(JSON.value(in: object, for: ["count", "requests", "request_count"])).map { Int($0) } ?? 1,
            lastSeen: JSON.date(JSON.value(in: object, for: ["last_seen", "lastSeen", "last_seen_at", "timestamp", "time"]))
        )
    }

    private static func entryDecision(_ object: [String: Any]) -> NetworkDecision? {
        if let text = JSON.string(JSON.value(in: object, for: ["decision", "status", "result"])), let decision = NetworkDecision(text) {
            return decision
        }
        // `string` reads booleans as "Yes" or "No".
        if let blocked = JSON.string(JSON.value(in: object, for: ["blocked"])) {
            return blocked == "Yes" ? .deny : .allow
        }
        if let allowed = JSON.string(JSON.value(in: object, for: ["allowed"])) {
            return allowed == "Yes" ? .allow : .deny
        }
        return nil
    }
}
