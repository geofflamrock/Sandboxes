import SwiftUI

struct ContentView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(SecretStore.self) private var secrets
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SandboxSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if store.selection == .secrets {
                SecretsView()
            } else if let sandbox = store.selectedSandbox {
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
        .alert(
            secrets.actionError?.title ?? "",
            isPresented: Binding(
                get: { secrets.actionError != nil },
                set: { if !$0 { secrets.actionError = nil } }
            ),
            presenting: secrets.actionError
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.message)
        }
        .background(WindowReader(kind: .main))
        .onAppear {
            AppWindows.openMain = { openWindow(id: AppWindows.mainID) }
            AppWindows.openCreate = { openWindow(id: AppWindows.createID) }
            store.windowDidOpen()
        }
        .onDisappear {
            store.windowDidClose()
        }
    }
}

struct SandboxSidebar: View {
    @Environment(SandboxStore.self) private var store
    @Environment(SecretStore.self) private var secrets
    @Environment(UpdateChecker.self) private var updates
    @State private var searchText = ""
    @AppStorage("sidebarSandboxesExpanded") private var sandboxesExpanded = true
    @AppStorage("sidebarManagementExpanded") private var managementExpanded = true

    private var filteredSandboxes: [Sandbox] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.sandboxes }
        return store.sandboxes.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selection) {
            Section("Sandboxes", isExpanded: $sandboxesExpanded) {
                ForEach(filteredSandboxes) { sandbox in
                    SandboxRow(
                        sandbox: sandbox,
                        isBusy: store.isBusy(sandbox),
                        pendingApprovals: store.approvals(for: sandbox).count
                    )
                    .tag(SidebarItem.sandbox(sandbox.id))
                }
                sandboxesPlaceholder
            }
            // Search only filters sandboxes, so these stay put.
            Section("Management", isExpanded: $managementExpanded) {
                Label("Secrets", systemImage: "key")
                    .badge(secrets.secrets.count)
                    .tag(SidebarItem.secrets)
                    .help("API keys, tokens and registry credentials sbx gives sandboxes")
            }
        }
        // Removing a sandbox also removes its secrets, so keep the count right.
        .task(id: store.sandboxes.map(\.name)) {
            await secrets.refresh()
        }
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if let sandbox = sandbox(for: items) {
                SandboxActionButtons(sandbox: sandbox)
            }
        } primaryAction: { items in
            if let sandbox = sandbox(for: items) {
                Task { await store.open(sandbox, in: store.defaultOpenTarget) }
            }
        }
        .onDeleteCommand {
            store.removalCandidate = store.selectedSandbox
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
                // On one line when they fit, otherwise the sbx badges go below.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        versionBadge
                        SbxStatusBadges()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        versionBadge
                        HStack(spacing: 6) {
                            SbxStatusBadges()
                        }
                    }
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

    private func sandbox(for items: Set<SidebarItem>) -> Sandbox? {
        guard case let .sandbox(id) = items.first else { return nil }
        return store.sandboxes.first { $0.id == id }
    }

    /// Shown in the Sandboxes section in place of rows, so the Management
    /// section stays visible while there are no sandboxes to list.
    @ViewBuilder
    private var sandboxesPlaceholder: some View {
        if !store.hasLoaded {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        } else if store.sandboxes.isEmpty {
            if let error = store.loadError {
                SidebarPlaceholder(
                    title: "Can't Load Sandboxes",
                    systemImage: "exclamationmark.triangle",
                    message: error
                ) {
                    Button("Try Again") { Task { await store.refresh() } }
                    SettingsLink { Text("Settings…") }
                }
            } else {
                SidebarPlaceholder(
                    title: "No Sandboxes",
                    systemImage: "shippingbox",
                    message: "Create a sandbox to get started."
                ) {
                    Button("New Sandbox") { store.presentCreate() }
                        .buttonStyle(.glassProminent)
                }
            }
        } else if filteredSandboxes.isEmpty {
            SidebarPlaceholder(
                title: "No Results",
                systemImage: "magnifyingglass",
                message: "No sandboxes match “\(searchText)”."
            ) {
                EmptyView()
            }
        }
    }

    /// Releases show their version; other builds show what they are built
    /// from, so it's obvious when this isn't a release.
    private var versionBadge: some View {
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
    }
}

/// A short message in place of a sidebar section's rows, such as when there
/// are no sandboxes.
private struct SidebarPlaceholder<Actions: View>: View {
    let title: String
    let systemImage: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            HStack {
                actions
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .selectionDisabled()
    }
}

/// Capsules in the sidebar footer summarizing sbx: whether it's installed and
/// whether `sbx diagnose` found problems, and a newer version when there is
/// one. When a newer version is all there is to report, only it shows.
private struct SbxStatusBadges: View {
    @Environment(SbxStatus.self) private var sbxStatus

    var body: some View {
        let upgrade = self.upgrade
        if let status = status(upgrade: upgrade) {
            SbxBadge(color: status.color, text: status.text, help: status.help)
        }
        if let upgrade {
            SbxBadge(color: .orange, text: upgrade, help: "\(upgrade). Click to see Settings › sbx.")
        }
    }

    /// Such as "sbx 0.49.0 available", whether the app's own check for
    /// releases or sbx diagnose found it.
    private var upgrade: String? {
        if let release = sbxStatus.availableUpgrade {
            return "sbx \(release.version) available"
        }
        if sbxStatus.diagnostics?.checks.contains(where: \.isUpgradeWarning) == true {
            return "sbx upgrade available"
        }
        return nil
    }

    /// The installation and diagnostics, or nil when there's nothing to say
    /// besides the newer version.
    private func status(upgrade: String?) -> (color: Color, text: String, help: String)? {
        switch sbxStatus.state {
        case .checking:
            return (.secondary, "Checking sbx…", "Looking for sbx")
        case .notInstalled:
            return (.red, "sbx not installed", "sbx isn't installed. Click to see Settings › sbx.")
        case .installed:
            break
        }
        guard let diagnostics = sbxStatus.diagnostics else {
            if let error = sbxStatus.diagnosticsError {
                return (.red, "sbx diagnose failed", "Couldn't run sbx diagnose: \(error)")
            }
            if upgrade != nil { return nil }
            return (.secondary, "Checking sbx…", "Running sbx diagnose")
        }
        let failures = diagnostics.failures
        // The newer version has its own badge.
        let warnings = diagnostics.warnings.filter { !$0.isUpgradeWarning }
        let details = (failures + warnings)
            .map { $0.message.isEmpty ? $0.name : "\($0.name): \($0.message)" }
            .joined(separator: "\n")
        if !failures.isEmpty {
            let text = failures.count == 1 ? "1 problem" : "\(failures.count.formatted()) problems"
            return (.red, text, details)
        }
        if !warnings.isEmpty {
            let text = warnings.count == 1 ? "1 warning" : "\(warnings.count.formatted()) warnings"
            return (.orange, text, details)
        }
        if upgrade != nil { return nil }
        return (.green, "Healthy", "All \(diagnostics.count(.pass).formatted()) sbx diagnose checks passed")
    }
}

/// A capsule with a status dot and a short summary that opens Settings › sbx.
private struct SbxBadge: View {
    let color: Color
    let text: String
    let help: String
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            SettingsTab.show(.sbx, openSettings)
        } label: {
            HStack(spacing: 5) {
                StatusDot(color: color)
                Text(text)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(help)
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
