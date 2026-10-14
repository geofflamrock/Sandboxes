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

    func isBusy(_ sandbox: Sandbox) -> Bool {
        busyNames.contains(sandbox.name)
    }

    private func load() async {
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
