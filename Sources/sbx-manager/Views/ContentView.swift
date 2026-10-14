import SwiftUI

struct ContentView: View {
    @Environment(SandboxStore.self) private var store

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            SandboxSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let sandbox = store.selectedSandbox {
                SandboxDetailView(sandbox: sandbox)
            } else {
                ContentUnavailableView("No Sandbox Selected", systemImage: "shippingbox")
            }
        }
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
        .task {
            await store.refreshPeriodically()
        }
    }
}

struct SandboxSidebar: View {
    @Environment(SandboxStore.self) private var store

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selection) {
            ForEach(store.sandboxes) { sandbox in
                SandboxRow(sandbox: sandbox, isBusy: store.isBusy(sandbox))
            }
        }
        .contextMenu(forSelectionType: Sandbox.ID.self) { ids in
            if let id = ids.first, let sandbox = store.sandboxes.first(where: { $0.id == id }) {
                SandboxActionButtons(sandbox: sandbox)
            }
        } primaryAction: { ids in
            if let id = ids.first, let sandbox = store.sandboxes.first(where: { $0.id == id }) {
                store.openInTerminal(sandbox)
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
                        Button("New Sandbox") { store.isCreatePresented = true }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = store.loadError, !store.sandboxes.isEmpty {
                Label("Couldn't refresh: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 10))
                    .padding(8)
                    .help(error)
            }
        }
        .navigationTitle("Sandboxes")
        .toolbar {
            // Declared on the sidebar so it sits above the sidebar, leaving the
            // window's trailing toolbar for actions on the selected sandbox.
            ToolbarItem {
                Button("New Sandbox", systemImage: "plus") {
                    store.isCreatePresented = true
                }
                .help("Create a new sandbox")
            }
        }
    }
}

struct SandboxRow: View {
    let sandbox: Sandbox
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
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
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(sandbox.state.color)
                    .frame(width: 8, height: 8)
                    .help(sandbox.statusLabel)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Start/stop, open and remove actions, shared by menus and the toolbar.
struct SandboxActionButtons: View {
    let sandbox: Sandbox
    /// Menus separate Remove from the other actions; the toolbar doesn't.
    var showsDivider = true
    @Environment(SandboxStore.self) private var store

    var body: some View {
        if sandbox.state == .running {
            Button("Stop", systemImage: "stop.fill") {
                Task { await store.stop(sandbox) }
            }
            .disabled(store.isBusy(sandbox))
        } else {
            Button("Start", systemImage: "play.fill") {
                Task { await store.start(sandbox) }
            }
            .disabled(store.isBusy(sandbox) || sandbox.state == .transitioning)
        }
        Button("Open in Terminal", systemImage: "apple.terminal") {
            store.openInTerminal(sandbox)
        }
        Button {
            Task { await store.openInClaudeDesktop(sandbox) }
        } label: {
            Label {
                Text("Open in Claude Desktop")
            } icon: {
                ClaudeDesktopIcon()
            }
        }
        .disabled(store.isBusy(sandbox))
        if showsDivider {
            Divider()
        }
        Button("Remove…", systemImage: "trash", role: .destructive) {
            store.removalCandidate = sandbox
        }
        .disabled(store.isBusy(sandbox))
    }
}
