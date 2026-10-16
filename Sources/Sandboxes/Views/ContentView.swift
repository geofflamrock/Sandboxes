import SwiftUI

struct ContentView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            SandboxSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let sandbox = store.selectedSandbox {
                SandboxDetailView(sandbox: sandbox)
            } else {
                HomeView()
            }
        }
        // The window starts with a non-scrolling detail view, so AppKit draws a
        // hard titlebar separator and doesn't drop it when the Form arrives
        // until the window next lays out. Hide it; scroll edge effects still
        // mark the toolbar edge when content scrolls under it.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(isPresented: $store.isCreatePresented) {
            CreateSandboxView()
        }
        .confirmationDialog(
            "Remove “\(store.removalCandidate?.name ?? "")”?",
            isPresented: Binding(
                get: { store.removalCandidate != nil },
                set: { if !$0 { store.removalCandidate = nil } }
            ),
            presenting: store.removalCandidate
        ) { sandbox in
            Button("Remove", role: .destructive) {
                Task { await store.remove(sandbox) }
            }
        } message: { _ in
            Text("This stops the sandbox and deletes its containers, state and scoped secrets. This can't be undone.")
        }
        .alert(
            store.actionError?.title ?? "",
            isPresented: Binding(
                get: { store.actionError != nil },
                set: { if !$0 { store.actionError = nil } }
            ),
            presenting: store.actionError
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.message)
        }
        .background(WindowReader(kind: .main))
        .onAppear {
            AppWindows.openMain = { openWindow(id: AppWindows.mainID) }
            store.windowDidOpen()
        }
        .onDisappear {
            store.windowDidClose()
        }
    }
}

struct SandboxSidebar: View {
    @Environment(SandboxStore.self) private var store
    @Environment(UpdateChecker.self) private var updates
    @State private var searchText = ""

    private var filteredSandboxes: [Sandbox] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.sandboxes }
        return store.sandboxes.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selection) {
            ForEach(filteredSandboxes) { sandbox in
                SandboxRow(
                    sandbox: sandbox,
                    isBusy: store.isBusy(sandbox),
                    pendingApprovals: store.approvals(for: sandbox).count
                )
            }
        }
        .contextMenu(forSelectionType: Sandbox.ID.self) { ids in
            if let id = ids.first, let sandbox = store.sandboxes.first(where: { $0.id == id }) {
                SandboxActionButtons(sandbox: sandbox)
            }
        } primaryAction: { ids in
            if let id = ids.first, let sandbox = store.sandboxes.first(where: { $0.id == id }) {
                Task { await store.open(sandbox, in: store.defaultOpenTarget) }
            }
        }
        .onDeleteCommand {
            store.removalCandidate = store.selectedSandbox
        }
        .overlay {
            if !store.hasLoaded {
                ProgressView()
            } else if store.sandboxes.isEmpty {
                if let error = store.loadError {
                    ContentUnavailableView {
                        Label("Can't Load Sandboxes", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await store.refresh() } }
                        SettingsLink { Text("Settings…") }
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Sandboxes", systemImage: "shippingbox")
                    } description: {
                        Text("Create a sandbox to get started.")
                    } actions: {
                        Button("New Sandbox") { store.presentCreate() }
                            .buttonStyle(.glassProminent)
                    }
                }
            } else if filteredSandboxes.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search sandboxes")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if let error = store.loadError, !store.sandboxes.isEmpty {
                    Label("Couldn't refresh: \(error)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(8)
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                        .help(error)
                }
                if let update = updates.availableUpdate {
                    Link(destination: update.url) {
                        Label("Version \(update.version) available", systemImage: "arrow.down.circle.fill")
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .help("Download Sandboxes \(update.version) from GitHub")
                }
                HStack(spacing: 6) {
                    // Releases show their version; other builds show what they are
                    // built from, so it's obvious when this isn't a release.
                    Group {
                        if let label = AppInfo.buildLabel {
                            Label(label, systemImage: "hammer.fill")
                                .help("\(label) build \(AppInfo.build) of version \(AppInfo.version)")
                        } else {
                            Label("v\(AppInfo.version)", systemImage: "tag.fill")
                                .help("Version \(AppInfo.version), build \(AppInfo.build)")
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    SbxStatusBadge()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .navigationTitle("Sandboxes")
        .toolbar {
            // Declared on the sidebar so it sits above the sidebar, leaving the
            // window's trailing toolbar for actions on the selected sandbox.
            ToolbarItem {
                Button("New Sandbox", systemImage: "plus") {
                    store.presentCreate()
                }
                .help("Create a new sandbox")
            }
        }
    }
}

/// A capsule in the sidebar footer summarizing sbx: whether it's installed,
/// whether `sbx diagnose` found problems, or a newer version. Clicking it
/// opens Settings › sbx.
private struct SbxStatusBadge: View {
    @Environment(SbxStatus.self) private var sbxStatus
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let summary = self.summary
        Button {
            SettingsTab.show(.sbx, openSettings)
        } label: {
            HStack(spacing: 5) {
                StatusDot(color: summary.color)
                Text(summary.text)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(summary.help)
    }

    private var summary: (color: Color, text: String, help: String) {
        switch sbxStatus.state {
        case .checking:
            return (.secondary, "Checking sbx…", "Looking for sbx")
        case .notInstalled:
            return (.red, "sbx not installed", "sbx isn't installed. Click to see Settings › sbx.")
        case .installed:
            break
        }
        let upgrade = sbxStatus.availableUpgrade
        guard let diagnostics = sbxStatus.diagnostics else {
            if let error = sbxStatus.diagnosticsError {
                return (.red, "sbx diagnose failed", "Couldn't run sbx diagnose: \(error)")
            }
            if let upgrade {
                return (.orange, "sbx \(upgrade.version) available", "sbx \(upgrade.version) is available. Click to see Settings › sbx.")
            }
            return (.secondary, "Checking sbx…", "Running sbx diagnose")
        }
        let failures = diagnostics.failures
        let warnings = diagnostics.warnings
        let details = (failures + warnings)
            .map { $0.message.isEmpty ? $0.name : "\($0.name): \($0.message)" }
            .joined(separator: "\n")
        if !failures.isEmpty {
            let text = failures.count == 1 ? "sbx: 1 problem" : "sbx: \(failures.count.formatted()) problems"
            return (.red, text, details)
        }
        // A newer version on its own gets its own wording, whether sbx
        // diagnose or the app's own check for releases found it.
        if warnings.allSatisfy(\.isUpgradeWarning), upgrade != nil || !warnings.isEmpty {
            let text = upgrade.map { "sbx \($0.version) available" } ?? "sbx upgrade available"
            return (.orange, text, details.isEmpty ? "\(text). Click to see Settings › sbx." : details)
        }
        if !warnings.isEmpty {
            let text = warnings.count == 1 ? "sbx: 1 warning" : "sbx: \(warnings.count.formatted()) warnings"
            return (.orange, text, details)
        }
        return (.green, "sbx healthy", "All \(diagnostics.count(.pass).formatted()) sbx diagnose checks passed")
    }
}

struct SandboxRow: View {
    let sandbox: Sandbox
    let isBusy: Bool
    var pendingApprovals = 0

    var body: some View {
        HStack(spacing: 8) {
            AgentIcon(agent: sandbox.knownAgent)
                .foregroundStyle(sandbox.knownAgent?.color ?? .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(sandbox.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(sandbox.agent ?? sandbox.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if pendingApprovals > 0 {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                    .help(pendingApprovals == 1 ? "1 network request waiting for approval" : "\(pendingApprovals) network requests waiting for approval")
            }
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                StatusDot(color: sandbox.state.color)
                    .help(sandbox.statusLabel)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Start/stop, shell, run/open and remove actions, shared by menus and the toolbar.
struct SandboxActionButtons: View {
    enum Placement {
        case menu
        case toolbar
    }

    let sandbox: Sandbox
    var placement = Placement.menu
    @Environment(SandboxStore.self) private var store

    var body: some View {
        if sandbox.state == .running {
            Button("Stop", systemImage: "stop") {
                Task { await store.stop(sandbox) }
            }
            .disabled(store.isBusy(sandbox))
        } else {
            Button("Start", systemImage: "play") {
                Task { await store.start(sandbox) }
            }
            .disabled(store.isBusy(sandbox) || sandbox.state == .transitioning)
        }
        Button("Open Shell", systemImage: "terminal") {
            store.openShell(in: sandbox)
        }
        .help("Open an interactive shell inside the sandbox in the default terminal")
        .disabled(store.isBusy(sandbox) || sandbox.state == .transitioning)
        switch placement {
        case .menu:
            // Menus can't hold a split button, so list each way to open.
            // Double-clicking uses the default.
            OpenTargetButtons(sandbox: sandbox)
            Divider()
        case .toolbar:
            OpenSplitButton(sandbox: sandbox)
        }
        Button("Remove…", systemImage: "trash", role: .destructive) {
            store.removalCandidate = sandbox
        }
        .disabled(store.isBusy(sandbox))
    }
}

/// Opens a sandbox the way one was last opened, with every way to open it in
/// the menu.
struct OpenSplitButton: View {
    let sandbox: Sandbox
    @Environment(SandboxStore.self) private var store

    var body: some View {
        let target = store.defaultOpenTarget
        Menu {
            OpenTargetButtons(sandbox: sandbox)
                .labelStyle(.titleAndIcon)
        } label: {
            OpenTargetLabel(target: target, agent: sandbox.knownAgent)
        } primaryAction: {
            Task { await store.open(sandbox, in: target) }
        }
        .help(target.title(for: sandbox.knownAgent))
        // A toolbar menu's AppKit item keeps the actions it was first built
        // with, so after switching sandbox or default target its items and
        // primary action would still open the old ones. Rebuild it instead.
        .id("\(sandbox.id)/\(target.rawValue)")
    }
}

/// A button for each way a sandbox can be opened.
struct OpenTargetButtons: View {
    let sandbox: Sandbox
    @Environment(SandboxStore.self) private var store

    var body: some View {
        ForEach(OpenTarget.allCases) { target in
            Button {
                Task { await store.open(sandbox, in: target) }
            } label: {
                OpenTargetLabel(target: target, agent: sandbox.knownAgent)
            }
            .disabled(!store.canOpen(sandbox, in: target))
        }
    }
}

struct OpenTargetLabel: View {
    let target: OpenTarget
    /// Terminal runs the agent, so it's named after it and shows its logo.
    var agent: Agent?

    var body: some View {
        Label {
            Text(target.title(for: agent))
        } icon: {
            switch target {
            case .terminal: agent?.menuIcon ?? Image(systemName: "apple.terminal")
            case .claudeDesktop: ClaudeDesktopIcon()
            }
        }
    }
}
