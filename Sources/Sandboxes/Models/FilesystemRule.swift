import Foundation

/// A file system rule that applies to a sandbox, from `sbx policy ls`. Allow
/// rules name the host paths a sandbox can mount as a workspace. They're
/// checked when the workspace is mounted, as the sandbox is created.
///
/// They come from the default policy or an organization's policies. As of
/// v0.48.0, `sbx policy allow`, `deny` and `rm` only take network rules, and
/// approvals are only asked for network access, so they can't be changed here.
struct FilesystemRule: Identifiable, Hashable {
    enum Access: Hashable {
        case read
        case write
    }

    let id: String
    let decision: PolicyDecision
    /// Host path patterns such as `~/**`.
    let paths: [String]
    /// A writable workspace needs both a read and a write rule. Empty if
    /// `sbx` doesn't say.
    let access: Set<Access>
    /// Where the rule came from: `local`, `kit` or `org`.
    let source: String?
    /// `all` for a global rule, or `sandbox:NAME` for one scoped to a sandbox.
    let appliesTo: String?

    /// The sandbox a rule is scoped to, or nil for a global rule.
    var sandboxName: String? {
        guard let appliesTo, appliesTo.lowercased().hasPrefix("sandbox:") else { return nil }
        let name = appliesTo.dropFirst("sandbox:".count)
        return name.isEmpty ? nil : String(name)
    }

    static func fetch(for sandbox: Sandbox) async throws -> [FilesystemRule] {
        let output = try await SbxCLI.runChecked(["policy", "ls", sandbox.name, "--type", "filesystem", "--json"])
        return PolicyParser.filesystemRules(in: try PolicyParser.document(output))
    }
}
