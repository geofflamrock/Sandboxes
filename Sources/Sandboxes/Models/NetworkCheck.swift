import Foundation

/// Whether the network policy lets a sandbox reach a host, from
/// `sbx policy check network`.
struct NetworkCheckResult: Identifiable, Hashable {
    enum Outcome: Hashable {
        case allowed
        case denied
        /// A decision this app doesn't know, such as asking for approval.
        case other(String)
        /// sbx couldn't check, with what it printed.
        case failed(String)
    }

    /// The sandbox checked, or nil for the global policy.
    let sandbox: String?
    let outcome: Outcome
    /// The rule that decided it, or why, when sbx says.
    let detail: String?

    var id: String { sandbox ?? "" }

    /// Checks `target`, a host, `host:port`, IP address or URL, for
    /// `sandbox`, or against the global policy when it's nil.
    static func check(
        _ target: String,
        sandbox: String?,
        protocols: NetworkRuleDraft.Protocols
    ) async -> NetworkCheckResult {
        var arguments = ["policy", "check", "network"]
        if let sandbox {
            arguments += ["--sandbox", sandbox]
        }
        // A check takes one protocol, so "TCP and UDP" isn't offered.
        if let protocols = protocols.argument, protocols != "tcp,udp" {
            arguments += ["--protocol", protocols]
        }
        arguments += ["--json", target]
        do {
            let result = try await SbxCLI.run(arguments)
            return NetworkCheckParser.result(from: result, sandbox: sandbox)
        } catch {
            return NetworkCheckResult(sandbox: sandbox, outcome: .failed(error.localizedDescription), detail: nil)
        }
    }
}

/// Parses `sbx policy check network --json`. Its output isn't documented, so
/// this looks for a decision and the rule or reason behind it under several
/// key spellings, one level deep, and shows the output as it is otherwise.
enum NetworkCheckParser {
    typealias JSON = SandboxListParser

    static func result(from result: CommandResult, sandbox: String?) -> NetworkCheckResult {
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // A denial may exit with an error, so read the JSON whatever the status.
        if let json = try? PolicyParser.document(output),
           let object = (json as? [String: Any]) ?? (json as? [Any])?.first as? [String: Any],
           let outcome = outcome(in: object) {
            return NetworkCheckResult(sandbox: sandbox, outcome: outcome, detail: detail(in: object))
        }
        if !result.succeeded {
            return NetworkCheckResult(sandbox: sandbox, outcome: .failed(output.isEmpty ? "sbx exited with code \(result.exitCode)." : output), detail: nil)
        }
        return NetworkCheckResult(sandbox: sandbox, outcome: .other("Unknown"), detail: output.isEmpty ? nil : output)
    }

    /// The object and the objects directly inside it, such as a `result`.
    private static func candidates(_ object: [String: Any]) -> [[String: Any]] {
        [object] + object.values.compactMap { $0 as? [String: Any] }
    }

    private static func outcome(in object: [String: Any]) -> NetworkCheckResult.Outcome? {
        for candidate in candidates(object) {
            // `string` reads booleans as "Yes" or "No".
            if let allowed = JSON.string(JSON.value(in: candidate, for: ["allowed", "allow", "authorized", "permitted"])),
               allowed == "Yes" || allowed == "No" {
                return allowed == "Yes" ? .allowed : .denied
            }
            if let text = JSON.string(JSON.value(in: candidate, for: ["decision", "verdict", "outcome", "result", "effect", "action"])),
               !text.isEmpty {
                switch PolicyDecision(text) {
                case .allow: return .allowed
                case .deny: return .denied
                case nil: return .other(text.replacingOccurrences(of: "_", with: " ").capitalized)
                }
            }
        }
        return nil
    }

    /// The matching rule's hosts or name, and the reason, such as
    /// "api.example.com · Matched local allow rule".
    private static func detail(in object: [String: Any]) -> String? {
        var parts: [String] = []
        for candidate in candidates(object) {
            if parts.isEmpty, let rule = JSON.value(in: candidate, for: ["matched_rule", "matchedRule", "rule", "matched_by", "matched_rules", "rules"]) {
                let rules = rule as? [Any] ?? [rule]
                let names = rules.compactMap { item -> String? in
                    guard let rule = item as? [String: Any] else { return JSON.string(item) }
                    if let resources = JSON.value(in: rule, for: ["resources", "resource"]) {
                        return JSON.string(resources)
                    }
                    return JSON.string(JSON.value(in: rule, for: ["name", "id", "rule_id"]))
                }
                if !names.isEmpty {
                    parts.append(names.joined(separator: ", "))
                }
            }
            if let reason = JSON.string(JSON.value(in: candidate, for: ["reason", "message", "explanation", "detail", "details"])),
               !reason.isEmpty, !parts.contains(reason) {
                parts.append(reason)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
