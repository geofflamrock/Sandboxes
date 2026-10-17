import Foundation
import Observation

/// The secrets sbx has stored, globally and for each sandbox.
@MainActor
@Observable
final class SecretStore {
    private(set) var secrets: [SbxSecret] = []
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    /// Secrets with a removal in flight.
    private(set) var removingIDs: Set<SbxSecret.ID> = []

    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshAgain = false

    var globalSecrets: [SbxSecret] {
        secrets.filter { $0.scope == .global || $0.scope == .host }
    }

    struct SandboxSecrets: Identifiable {
        let sandbox: String
        let secrets: [SbxSecret]

        var id: String { sandbox }
    }

    /// Each sandbox with secrets of its own, by name.
    var sandboxSecrets: [SandboxSecrets] {
        Dictionary(grouping: secrets.filter { $0.scope.sandboxName != nil }) { $0.scope.sandboxName ?? "" }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { SandboxSecrets(sandbox: $0.key, secrets: $0.value) }
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

    /// Stores `value` as `service`'s secret, for `sandbox` or globally when
    /// it's nil, replacing any it already has there.
    func set(service: String, value: String, sandbox: String?) async throws {
        try await SbxCLI.runChecked(SbxSecret.setArguments(service: service, sandbox: sandbox), input: value)
        await refresh()
    }

    func remove(_ secret: SbxSecret) async throws {
        removingIDs.insert(secret.id)
        defer { removingIDs.remove(secret.id) }
        try await SbxCLI.runChecked(secret.removeArguments)
        await refresh()
    }

    func isRemoving(_ secret: SbxSecret) -> Bool {
        removingIDs.contains(secret.id)
    }
}
