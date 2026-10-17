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

    private(set) var secrets: [SbxSecret] = []
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    /// Secrets with a removal in flight.
    private(set) var removingIDs: Set<SbxSecret.ID> = []

    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshAgain = false

    var globalSecrets: [SbxSecret] {
        secrets.filter { $0.scope.sandboxName == nil }
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
            let latest = try await SbxSecret.fetch()
            if latest != secrets {
                secrets = latest
            }
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

    func remove(_ secrets: [SbxSecret]) async throws {
        let ids = Set(secrets.map(\.id))
        removingIDs.formUnion(ids)
        defer { removingIDs.subtract(ids) }
        do {
            for secret in secrets {
                guard let arguments = secret.removeArguments else { continue }
                try await SbxCLI.runChecked(arguments)
            }
        } catch {
            await refresh()
            throw error
        }
        await refresh()
    }

    func isRemoving(_ secret: SbxSecret) -> Bool {
        removingIDs.contains(secret.id)
    }
}
