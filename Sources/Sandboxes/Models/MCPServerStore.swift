import Foundation
import Observation

/// The MCP servers registered with sbx, and loading them into sandboxes.
@MainActor
@Observable
final class MCPServerStore {
    /// A server to unload from a sandbox once the user confirms.
    struct Unload: Identifiable {
        let id = UUID()
        let server: MCPServer
        let sandbox: Sandbox
    }

    private(set) var servers: [MCPServer] = []
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    /// Servers with an action in flight.
    private(set) var busyIDs: Set<MCPServer.ID> = []
    /// Sandboxes a server is being loaded into or unloaded from.
    private(set) var busySandboxes: Set<String> = []
    var unloadCandidate: Unload?
    /// The `sbx mcp auth` run shown in a sheet on the MCP Servers page.
    var authorisation: SbxCommandRun?
    var actionError: SandboxStore.ActionError?

    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshAgain = false

    init(secrets: SecretStore) {
        self.secrets = secrets
    }

    func server(named name: String) -> MCPServer? {
        servers.first { $0.name == name }
    }

    func isBusy(_ server: MCPServer) -> Bool {
        busyIDs.contains(server.id)
    }

    func isBusy(_ sandbox: Sandbox) -> Bool {
        busySandboxes.contains(sandbox.name)
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
            let latest = try await MCPServer.fetch()
            if latest != servers {
                servers = latest
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Registers the server and returns it as sbx now lists it. Throws so
    /// the Add Server sheet stays open with the error.
    func add(_ draft: MCPServerDraft) async throws -> MCPServer? {
        try await SbxCLI.runChecked(draft.addArguments)
        await refresh()
        return server(named: draft.trimmedName)
    }

    /// Removes the registration and, when `removingSecrets` is set, the
    /// secrets sbx keeps for it, which `sbx mcp rm` leaves behind.
    func remove(_ server: MCPServer, removingSecrets: Bool) async {
        await perform(on: server) {
            try await SbxCLI.runChecked(server.removeArguments)
            if removingSecrets {
                await secrets.refresh()
                for name in secrets.mcpSecretNames(forServer: server.name) {
                    try await SbxCLI.runChecked(["secret", "rm", name, "--force"])
                }
            }
        } failure: { "Couldn't Remove “\(server.name)”" }
        await secrets.refresh()
    }

    func removeCredentials(_ server: MCPServer) async {
        await perform(on: server) {
            try await SbxCLI.runChecked(server.removeCredentialsArguments)
        } failure: { "Couldn't Remove the Credentials for “\(server.name)”" }
    }

    /// Stores the values for header placeholders, keyed by placeholder.
    /// Throws so the sheet stays open with what was entered.
    func setHeaderSecrets(for server: String, values: [String: String]) async throws {
        for (placeholder, value) in values.sorted(by: { $0.key < $1.key }) {
            let name = MCPServerDetails.secretName(server: server, placeholder: placeholder)
            try await SbxCLI.runChecked(["secret", "set", name, "--force"], input: value)
        }
        await refresh()
        await secrets.refresh()
    }

    /// Removes a header placeholder's value and the record that ties it to
    /// the server's URL, which sbx keeps otherwise.
    func removeHeaderSecret(for server: String, placeholder: String) async throws {
        let name = MCPServerDetails.secretName(server: server, placeholder: placeholder)
        try await SbxCLI.runChecked(["secret", "rm", name, "--force"])
        await secrets.refresh()
        for metadata in secrets.mcpSecretNames(forServer: server) where metadata.hasPrefix(name + ":") {
            try await SbxCLI.runChecked(["secret", "rm", metadata, "--force"])
        }
        await refresh()
        await secrets.refresh()
    }

    /// Runs `sbx mcp auth` in a sheet. sbx opens the authorisation page in
    /// the browser itself and waits until it's approved or refused.
    func authorise(_ server: MCPServer) {
        let run = SbxCommandRun(kind: .authoriseMCP(server: server.name))
        run.start { [weak self] in
            Task { await self?.refresh() }
        }
        authorisation = run
    }

    func load(_ server: MCPServer, into sandbox: Sandbox) async {
        busySandboxes.insert(sandbox.name)
        defer { busySandboxes.remove(sandbox.name) }
        do {
            try await SbxCLI.runChecked(server.loadArguments(into: sandbox.name))
        } catch {
            actionError = SandboxStore.ActionError(title: "Couldn't Load “\(server.name)” into “\(sandbox.name)”", message: error.localizedDescription)
        }
    }

    func unload(_ server: MCPServer, from sandbox: Sandbox) async {
        busySandboxes.insert(sandbox.name)
        defer { busySandboxes.remove(sandbox.name) }
        do {
            try await SbxCLI.runChecked(server.unloadArguments(from: sandbox.name))
        } catch {
            actionError = SandboxStore.ActionError(title: "Couldn't Unload “\(server.name)” from “\(sandbox.name)”", message: error.localizedDescription)
        }
    }

    private func perform(on server: MCPServer, _ action: () async throws -> Void, failure title: () -> String) async {
        busyIDs.insert(server.id)
        do {
            try await action()
        } catch {
            actionError = SandboxStore.ActionError(title: title(), message: error.localizedDescription)
        }
        busyIDs.remove(server.id)
        await refresh()
    }
}
