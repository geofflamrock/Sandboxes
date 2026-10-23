import Foundation

/// Whether the network policy lets sandboxes reach a host, from
/// `sbx policy check network`.
struct NetworkCheckResult: Identifiable, Hashable {
    enum Outcome: Hashable {
        case allowed
        case denied
        /// sbx couldn't check, or printed something this app can't read.
        case failed(String)
    }

    let id = UUID()
    /// What was checked, such as `api.example.com:443`: sbx's form of the
    /// host entered, with the port it assumed.
    let target: String
    /// The sandbox checked, or nil for the global policy.
    let sandbox: String?
    let outcome: Outcome
    /// Such as "TCP", from sbx's action `net:connect:tcp`.
    var protocolName: String?
    /// Why, such as "No matching allow rule (default deny)", when sbx says.
    var reason: String?

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
            return NetworkCheckParser.result(from: result, target: target, sandbox: sandbox)
        } catch {
            return NetworkCheckResult(target: target, sandbox: sandbox, outcome: .failed(error.localizedDescription))
        }
    }
}

/// Parses `sbx policy check network --json`, which as of v0.49.1 prints:
///
///     {"action": "net:connect:tcp", "allowed": false, "context": "global",
///      "reason": "No matching allow rule (default deny)",
///      "target": "api.example.com:443", …}
///
/// `reason` is left out when the host is allowed.
enum NetworkCheckParser {
    typealias JSON = SandboxListParser

    static func result(from result: CommandResult, target: String, sandbox: String?) -> NetworkCheckResult {
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Read the JSON whatever the exit status, in case a denial exits with
        // an error.
        guard let json = try? PolicyParser.document(output),
              let object = json as? [String: Any],
              let outcome = outcome(in: object)
        else {
            let message = output.isEmpty ? "sbx exited with code \(result.exitCode)." : output
            return NetworkCheckResult(target: target, sandbox: sandbox, outcome: .failed(message))
        }
        let checked = JSON.string(JSON.value(in: object, for: ["target", "resource_value"])).flatMap { $0.isEmpty ? nil : $0 }
        let action = JSON.string(JSON.value(in: object, for: ["action"]))?.lowercased() ?? ""
        let reason = JSON.string(JSON.value(in: object, for: ["reason", "message"])).flatMap { $0.isEmpty ? nil : $0 }
        return NetworkCheckResult(
            target: checked ?? target,
            sandbox: sandbox,
            outcome: outcome,
            protocolName: action.hasSuffix("udp") ? "UDP" : action.hasSuffix("tcp") ? "TCP" : nil,
            reason: reason
        )
    }

    private static func outcome(in object: [String: Any]) -> NetworkCheckResult.Outcome? {
        // `string` reads booleans as "Yes" or "No".
        if let allowed = JSON.string(JSON.value(in: object, for: ["allowed"])), allowed == "Yes" || allowed == "No" {
            return allowed == "Yes" ? .allowed : .denied
        }
        return JSON.string(JSON.value(in: object, for: ["decision", "result"]))
            .flatMap { PolicyDecision($0) }
            .map { $0 == .allow ? .allowed : .denied }
    }
}
