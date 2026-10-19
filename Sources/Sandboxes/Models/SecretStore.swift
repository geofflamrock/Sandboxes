import Foundation
import Observation

/// The secrets sbx has stored, globally and for each sandbox.
@MainActor
@Observable
final class SecretStore {
    struct SandboxSecrets: Identifiable {
        let sandbox: String
        let secrets: [SbxSecret]

        var id: String { sandbox }
    }

    /// Everything sbx lists except the records it keeps next to MCP secrets.
    private(set) var secrets: [SbxSecret] = []
    /// Records such as `mcp:acme:api-key:endpoint`, kept so removing an MCP
    /// server can remove them too.
    @ObservationIgnored private(set) var mcpMetadata: [SbxSecret] = []
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    /// Secrets with a removal in flight.
    private(set) var removingIDs: Set<SbxSecret.ID> = []
    var actionError: SandboxStore.ActionError?

    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshAgain = false

    /// Global and host secrets, apart from MCP servers' secrets, which go
    /// to the MCP gateway rather than to sandboxes.
    var globalSecrets: [SbxSecret] {
        secrets.filter { $0.scope.sandboxName == nil && $0.kind != .mcp }
    }

    var mcpSecrets: [SbxSecret] {
        secrets.filter { $0.kind == .mcp }
    }

    /// The names of every secret and record sbx keeps for the MCP server
    /// `server`, such as `mcp:acme:api-key` and `mcp:acme:api-key:endpoint`.
    func mcpSecretNames(forServer server: String) -> [String] {
        (secrets + mcpMetadata)
            .filter { $0.mcpName?.server == server }
            .map(\.name)
    }

    /// Each sandbox with secrets of its own, by name.
    var sandboxSecrets: [SandboxSecrets] {
        Dictionary(grouping: secrets.filter { $0.scope.sandboxName != nil }) { $0.scope.sandboxName ?? "" }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { SandboxSecrets(sandbox: $0.key, secrets: $0.value) }
    }

    func secrets(for sandbox: String) -> [SbxSecret] {
        secrets.filter { $0.scope.sandboxName == sandbox }
    }

    /// Reloads the list. Calls made while a reload is in flight queue one
    /// more reload, so a change just made always shows.
    func refresh() async {
        if isRefreshing {
            refreshAgain = true
            return
        }
        isRefreshing = true
        repeat {
            refreshAgain = false
            await load()
        } while refreshAgain
        isRefreshing = false
    }

    private func load() async {
        do {
            let all = try await SbxSecret.fetch()
            let latest = all.filter { !$0.isMCPMetadata }
            if latest != secrets {
                secrets = latest
            }
            mcpMetadata = all.filter(\.isMCPMetadata)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Stores the secret, replacing any with the same name in its scope.
    func save(_ draft: SecretDraft) async throws {
        let invocation = draft.invocation
        try await SbxCLI.runChecked(invocation.arguments, input: invocation.input)
        await refresh()
    }

    func remove(_ secrets: [SbxSecret]) async {
        let ids = Set(secrets.map(\.id))
        removingIDs.formUnion(ids)
        defer { removingIDs.subtract(ids) }
        for secret in secrets {
            guard let arguments = secret.removeArguments else { continue }
            do {
                try await SbxCLI.runChecked(arguments)
            } catch {
                actionError = SandboxStore.ActionError(title: "Couldn't Remove “\(secret.title)”", message: error.localizedDescription)
                break
            }
        }
        await refresh()
    }

    func isRemoving(_ secret: SbxSecret) -> Bool {
        removingIDs.contains(secret.id)
    }
}
