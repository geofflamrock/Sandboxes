import Foundation
import Observation

/// What's selected in the sidebar: a sandbox, or one of the management pages.
enum SidebarItem: Hashable {
    case sandbox(Sandbox.ID)
    case environments
    case secrets
    case mcpServers
    case networkRules
    /// The settings of sbx itself, not this app's.
    case sbxSettings
}

/// An environment file opened in the New Sandbox window to edit, with the
/// options read from it.
struct EnvironmentEdit {
    let url: URL
    let request: CreateSandboxRequest
}

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
    /// Approvals with a response or deny in flight.
    private(set) var respondingApprovalIDs: Set<NetworkApproval.ID> = []
    var selection: SidebarItem?
    /// Whether the main window is open. While it's closed the app stays in
    /// the menu bar and only checks for pending approvals.
    private(set) var isWindowOpen = false
    /// A sandbox whose pending approvals its detail view should scroll to,
    /// after the user clicked a notification about them.
    var approvalsToReveal: Sandbox.ID?
    /// An MCP server the MCP Servers page should scroll to, after the user
    /// clicked Show Server on one of its secrets.
    var mcpServerToReveal: String?
    /// The workload image the New Sandbox window starts with, or nil for the
    /// most recently used one.
    private(set) var createWorkload: String?
    /// Counts requests to create a sandbox, so an open New Sandbox window can
    /// switch to the workload asked for.
    private(set) var createRequests = 0
    /// What the New Sandbox window makes when it opens: a sandbox or an
    /// environment file.
    private(set) var createTarget: CreateSandboxRequest.Target = .sandbox
    /// An environment file the New Sandbox window opens to edit.
    private(set) var environmentEdit: EnvironmentEdit?
    var removalCandidate: Sandbox?
    var actionError: ActionError?
    /// Where the open button and double-clicking open a sandbox: the last
    /// place one was opened, starting with Terminal.
    private(set) var defaultOpenTarget: OpenTarget = UserDefaults.standard
        .string(forKey: SandboxStore.defaultOpenTargetKey)
        .flatMap(OpenTarget.init(rawValue:)) ?? .terminal {
        didSet {
            UserDefaults.standard.set(defaultOpenTarget.rawValue, forKey: Self.defaultOpenTargetKey)
        }
    }

    nonisolated private static let defaultOpenTargetKey = "defaultOpenTarget"

    /// Called when the sandboxes stop loading, or don't load the first time,
    /// but not on every failed refresh after that.
    @ObservationIgnored var onLoadFailed: (@MainActor () -> Void)?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshAgain = false
    /// A sandbox to select once the sandbox list next loads.
    @ObservationIgnored private var pendingSelection: Sandbox.ID?

    var selectedSandbox: Sandbox? {
        guard case let .sandbox(id) = selection else { return nil }
        return sandboxes.first { $0.id == id }
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

    /// Refreshes every few seconds until the calling task is cancelled, less
    /// often while the window is closed.
    func refreshPeriodically() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(isWindowOpen ? 5 : 15))
        }
    }

    func windowDidOpen() {
        isWindowOpen = true
        // The sandbox list isn't kept up to date while the window is closed.
        Task { await refresh() }
    }

    func windowDidClose() {
        isWindowOpen = false
    }

    /// Opens the New Sandbox window, starting with `workload` when it's given.
    func presentCreate(workload: String? = nil) {
        createWorkload = workload
        createTarget = .sandbox
        environmentEdit = nil
        createRequests += 1
        AppWindows.showCreate()
    }

    /// Opens the New Sandbox window as New Environment File, to save one.
    func presentNewEnvironment() {
        createWorkload = nil
        createTarget = .environment
        environmentEdit = nil
        createRequests += 1
        AppWindows.showCreate()
    }

    /// Opens the New Sandbox window with an environment file's options, to save it again.
    func presentEdit(_ edit: EnvironmentEdit) {
        createWorkload = nil
        createTarget = .environment
        environmentEdit = edit
        createRequests += 1
        AppWindows.showCreate()
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

    /// Opens an interactive shell inside `sandbox` in the default terminal. `sbx exec`
    /// starts the sandbox first if it's stopped.
    func openShell(in sandbox: Sandbox) {
        do {
            try TerminalLauncher.open(sbxArguments: ["exec", "-it", sandbox.name, "bash"])
        } catch {
            actionError = ActionError(title: "Couldn't Open a Shell in “\(sandbox.name)”", message: error.localizedDescription)
        }
    }

    /// Opens `sandbox` in `target` and makes `target` the default.
    func open(_ sandbox: Sandbox, in target: OpenTarget) async {
        guard canOpen(sandbox, in: target) else { return }
        defaultOpenTarget = target
        switch target {
        case .terminal: openInTerminal(sandbox)
        case .claudeDesktop: await openInClaudeDesktop(sandbox)
        }
    }

    func canOpen(_ sandbox: Sandbox, in target: OpenTarget) -> Bool {
        switch target {
        case .terminal: true
        case .claudeDesktop: !isBusy(sandbox)
        }
    }

    private func openInTerminal(_ sandbox: Sandbox) {
        do {
            try TerminalLauncher.open(sbxArguments: ["run", "--name", sandbox.name])
        } catch {
            actionError = ActionError(title: "Couldn't Open Terminal", message: error.localizedDescription)
        }
    }

    private func openInClaudeDesktop(_ sandbox: Sandbox) async {
        busyNames.insert(sandbox.name)
        do {
            try await ClaudeDesktopLauncher.open(sandbox)
        } catch {
            actionError = ActionError(title: "Couldn't Open Claude Desktop", message: error.localizedDescription)
        }
        busyNames.remove(sandbox.name)
    }

    /// Shows the sandbox named `name` with its pending approvals, or Home,
    /// which lists every sandbox's, when there's no such sandbox.
    func showApprovals(forSandbox name: String?) {
        guard let name else {
            selection = nil
            return
        }
        approvalsToReveal = name
        if hasLoaded && sandboxes.contains(where: { $0.id == name }) {
            selection = .sandbox(name)
        } else {
            // Not loaded yet, or new since the list was last loaded, which it
            // isn't while the window is closed.
            selection = nil
            pendingSelection = name
        }
    }

    func approvals(for sandbox: Sandbox) -> [NetworkApproval] {
        approvals.filter { $0.sandbox == sandbox.name }
    }

    func isResponding(to approval: NetworkApproval) -> Bool {
        respondingApprovalIDs.contains(approval.id)
    }

    func respond(to approval: NetworkApproval, with option: NetworkApproval.Option) async {
        respondingApprovalIDs.insert(approval.id)
        do {
            try await SbxCLI.runChecked(NetworkApproval.respondArguments(approval: approval, option: option))
        } catch {
            actionError = ActionError(title: "Couldn't Respond to the Request for “\(approval.title)”", message: error.localizedDescription)
        }
        await finishResponding(to: [approval])
    }

    /// Adds an allow rule for the destination for every sandbox, then dismisses
    /// the request and other sandboxes' requests for the same host. Responding
    /// with the allow option would also add a rule scoped to each sandbox,
    /// which the global rule already covers.
    func approveForAllSandboxes(_ approval: NetworkApproval) async {
        let host = approval.target.host.lowercased()
        let approved = [approval] + approvals.filter { $0.id != approval.id && $0.target.host.lowercased() == host }
        respondingApprovalIDs.formUnion(approved.map(\.id))
        do {
            try await SbxCLI.runChecked(NetworkApproval.allowArguments(approval: approval, sandbox: nil))
            for pending in approved {
                if let dismiss = pending.dismissOption {
                    try await SbxCLI.runChecked(NetworkApproval.respondArguments(approval: pending, option: dismiss))
                }
            }
        } catch {
            actionError = ActionError(title: "Couldn't Allow Access to “\(approval.title)”", message: error.localizedDescription)
        }
        await finishResponding(to: approved)
    }

    /// Adds a deny rule for the destination, for `sandbox` or for every sandbox
    /// when it's nil, then dismisses the request so it no longer shows as
    /// pending. Denying for every sandbox also dismisses other sandboxes'
    /// requests for the same host.
    func deny(_ approval: NetworkApproval, in sandbox: Sandbox?) async {
        var dismissed = [approval]
        if sandbox == nil {
            let host = approval.target.host.lowercased()
            dismissed += approvals.filter { $0.id != approval.id && $0.target.host.lowercased() == host }
        }
        respondingApprovalIDs.formUnion(dismissed.map(\.id))
        do {
            try await SbxCLI.runChecked(NetworkApproval.denyArguments(approval: approval, sandbox: sandbox?.name))
            for pending in dismissed {
                if let dismiss = pending.dismissOption {
                    try await SbxCLI.runChecked(NetworkApproval.respondArguments(approval: pending, option: dismiss))
                }
            }
        } catch {
            actionError = ActionError(title: "Couldn't Deny Access to “\(approval.title)”", message: error.localizedDescription)
        }
        await finishResponding(to: dismissed)
    }

    /// Reloads the pending approvals before clearing the spinner, so a request
    /// that was answered doesn't flash back, then refreshes everything else.
    private func finishResponding(to answered: [NetworkApproval]) async {
        if let latest = try? await NetworkApproval.fetch() {
            setApprovals(latest)
        }
        respondingApprovalIDs.subtract(answered.map(\.id))
        await refresh()
    }

    func isBusy(_ sandbox: Sandbox) -> Bool {
        busyNames.contains(sandbox.name)
    }

    private func load() async {
        async let latestApprovals = try? NetworkApproval.fetch()
        if hasLoaded && !isWindowOpen {
            if let latest = await latestApprovals {
                setApprovals(latest)
            }
            return
        }
        do {
            let output = try await SbxCLI.runChecked(["ls", "--json"])
            sandboxes = try SandboxListParser.parse(output)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loadError = nil
            if let pendingSelection {
                self.pendingSelection = nil
                if sandboxes.contains(where: { $0.id == pendingSelection }) {
                    selection = .sandbox(pendingSelection)
                }
            }
            if case let .sandbox(id) = selection, !sandboxes.contains(where: { $0.id == id }) {
                selection = nil
            }
        } catch {
            let wasFailing = loadError != nil
            loadError = error.localizedDescription
            if !wasFailing {
                onLoadFailed?()
            }
        }
        hasLoaded = true
        // Approvals are an extra; if sbx can't list them, keep the last list.
        if let latest = await latestApprovals {
            setApprovals(latest)
        }
    }

    private func setApprovals(_ latest: [NetworkApproval]) {
        if latest != approvals {
            approvals = latest
        }
        ApprovalNotifier.shared.update(latest)
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
