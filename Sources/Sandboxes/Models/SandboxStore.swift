import Foundation
import Observation

@MainActor
@Observable
final class SandboxStore {
    struct ActionError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private(set) var sandboxes: [Sandbox] = []
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private(set) var busyNames: Set<String> = []
    /// Pending network approvals for every sandbox.
    private(set) var approvals: [NetworkApproval] = []
    var selection: Sandbox.ID?
    var isCreatePresented = false
    var removalCandidate: Sandbox?
    var actionError: ActionError?

    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshAgain = false

    var selectedSandbox: Sandbox? {
        sandboxes.first { $0.id == selection }
    }

    /// Reloads the list. Calls made while a reload is in flight queue one more reload.
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

    /// Refreshes every few seconds until the calling task is cancelled.
    func refreshPeriodically() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func start(_ sandbox: Sandbox) async {
        await perform(["run", "--detach", "--name", sandbox.name], on: sandbox, failure: "Couldn't Start “\(sandbox.name)”")
    }

    func stop(_ sandbox: Sandbox) async {
        await perform(["stop", sandbox.name], on: sandbox, failure: "Couldn't Stop “\(sandbox.name)”")
    }

    func remove(_ sandbox: Sandbox) async {
        await perform(["rm", "--force", sandbox.name], on: sandbox, failure: "Couldn't Remove “\(sandbox.name)”")
    }

    func openInTerminal(_ sandbox: Sandbox) {
        do {
            try TerminalLauncher.open(sbxArguments: ["run", "--name", sandbox.name])
        } catch {
            actionError = ActionError(title: "Couldn't Open Terminal", message: error.localizedDescription)
        }
    }

    func openInClaudeDesktop(_ sandbox: Sandbox) async {
        busyNames.insert(sandbox.name)
        do {
            try await ClaudeDesktopLauncher.open(sandbox)
        } catch {
            actionError = ActionError(title: "Couldn't Open Claude Desktop", message: error.localizedDescription)
        }
        busyNames.remove(sandbox.name)
    }

    func approvals(for sandbox: Sandbox) -> [NetworkApproval] {
        approvals.filter { $0.sandbox == sandbox.name }
    }

    func respond(to approval: NetworkApproval, with option: NetworkApproval.Option) async {
        do {
            try await SbxCLI.runChecked(NetworkApproval.respondArguments(approval: approval, option: option))
        } catch {
            actionError = ActionError(title: "Couldn't Respond to the Request for “\(approval.title)”", message: error.localizedDescription)
        }
        await refresh()
    }

    /// Adds a deny rule for the destination, for `sandbox` or for every sandbox
    /// when it's nil, then dismisses the request so it no longer shows as
    /// pending. Denying for every sandbox also dismisses other sandboxes'
    /// requests for the same host.
    func deny(_ approval: NetworkApproval, in sandbox: Sandbox?) async {
        do {
            try await SbxCLI.runChecked(NetworkApproval.denyArguments(approval: approval, sandbox: sandbox?.name))
            var dismissed = [approval]
            if sandbox == nil {
                let host = approval.target.host.lowercased()
                dismissed += approvals.filter { $0.id != approval.id && $0.target.host.lowercased() == host }
            }
            for pending in dismissed {
                if let dismiss = pending.dismissOption {
                    try await SbxCLI.runChecked(NetworkApproval.respondArguments(approval: pending, option: dismiss))
                }
            }
        } catch {
            actionError = ActionError(title: "Couldn't Deny Access to “\(approval.title)”", message: error.localizedDescription)
        }
        await refresh()
    }

    func isBusy(_ sandbox: Sandbox) -> Bool {
        busyNames.contains(sandbox.name)
    }

    private func load() async {
        async let latestApprovals = try? NetworkApproval.fetch()
        do {
            let output = try await SbxCLI.runChecked(["ls", "--json"])
            sandboxes = try SandboxListParser.parse(output)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loadError = nil
            if let selection, !sandboxes.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        } catch {
            loadError = error.localizedDescription
        }
        hasLoaded = true
        // Approvals are an extra; if sbx can't list them, keep the last list.
        if let latest = await latestApprovals, latest != approvals {
            approvals = latest
        }
    }

    private func perform(_ arguments: [String], on sandbox: Sandbox, failure title: String) async {
        busyNames.insert(sandbox.name)
        do {
            try await SbxCLI.runChecked(arguments)
        } catch {
            actionError = ActionError(title: title, message: error.localizedDescription)
        }
        busyNames.remove(sandbox.name)
        await refresh()
    }
}
