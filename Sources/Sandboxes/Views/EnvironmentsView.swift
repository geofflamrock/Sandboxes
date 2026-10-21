import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Management › Environments: environment files saved from the New Sandbox
/// window or opened from elsewhere, with ways to create a sandbox from one,
/// edit, open and delete them.
struct EnvironmentsView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(EnvironmentStore.self) private var environments
    /// A file the New Sandbox window can't edit, and why.
    @State private var uneditable: Uneditable?
    @State private var renaming: EnvironmentFile?
    @State private var newName = ""

    struct Uneditable: Identifiable {
        let id = UUID()
        let file: EnvironmentFile
        let reason: String
    }

    var body: some View {
        Form {
            Section {
                if environments.environments.isEmpty {
                    Text(environments.hasLoaded ? "No environments." : "Loading…")
                        .foregroundStyle(.secondary)
                }
                ForEach(environments.environments) { file in
                    EnvironmentRow(file: file, sandbox: sandbox(for: file)) { action in
                        perform(action, on: file)
                    }
                }
            } header: {
                Text("Environments")
            } footer: {
                Text("An environment file keeps a sandbox's agent, kits, workspace and settings, so you can create the same sandbox again or share it. New environments are saved in \((EnvironmentStore.directory.path as NSString).abbreviatingWithTildeInPath). Creating a sandbox shows what the file changes on your Mac first, including any commands it runs here.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Environments")
        .onAppear { environments.refresh() }
        // A file may have been changed in an editor.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            environments.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Home", systemImage: "chevron.backward") {
                    store.selection = nil
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Home")
            }
            ToolbarItem {
                Button("Open Environment File", systemImage: "folder") {
                    EnvironmentFilePanel.open(into: environments)
                }
                .help("Add an environment file from anywhere on your Mac to the list")
            }
            ToolbarItem {
                Button("New Environment", systemImage: "plus") {
                    store.presentNewEnvironment()
                }
                .help("Save a sandbox's options as an environment file")
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { environments.deletionCandidate != nil },
                set: { if !$0 { environments.deletionCandidate = nil } }
            ),
            presenting: environments.deletionCandidate
        ) { file in
            Button(file.isInLibrary ? "Move to Trash" : "Remove from List", role: .destructive) {
                environments.delete(file)
            }
        } message: { file in
            Text(file.isInLibrary
                ? "Its folder is moved to the Trash. Sandboxes already created from it aren't affected."
                : "The file stays where it is. Sandboxes already created from it aren't affected.")
        }
        .alert(
            "Rename “\(renaming?.displayName ?? "")”",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming
        ) { file in
            TextField("Name", text: $newName)
            Button("Rename") { rename(file) }
            Button("Cancel", role: .cancel) {}
        } message: { file in
            Text(file.isInLibrary
                ? "This changes the name in the file and its folder, and names the sandboxes it creates from now on. Sandboxes already created keep their names."
                : "This changes the name in the file, which names the sandboxes it creates from now on. Sandboxes already created keep their names.")
        }
        .alert(
            "Can't Edit “\(uneditable?.file.displayName ?? "")” Here",
            isPresented: Binding(get: { uneditable != nil }, set: { if !$0 { uneditable = nil } }),
            presenting: uneditable
        ) { uneditable in
            Button("Open in Editor") { environments.openInEditor(uneditable.file) }
            Button("Cancel", role: .cancel) {}
        } message: { uneditable in
            Text("\(uneditable.reason) Edit the file in a text editor instead, so nothing is lost.")
        }
    }

    private var deletionTitle: String {
        guard let file = environments.deletionCandidate else { return "" }
        return file.isInLibrary ? "Delete “\(file.displayName)”?" : "Remove “\(file.displayName)” from the List?"
    }

    private func sandbox(for file: EnvironmentFile) -> Sandbox? {
        guard let name = file.sandboxName else { return nil }
        return store.sandboxes.first { $0.name == name }
    }

    private func perform(_ action: EnvironmentRow.Action, on file: EnvironmentFile) {
        switch action {
        case .create: environments.startCreating(from: file)
        case .runInTerminal: environments.runInTerminal(file)
        case .showSandbox:
            if let sandbox = sandbox(for: file) {
                store.selection = .sandbox(sandbox.id)
            }
        case .rename:
            newName = file.name ?? file.displayName
            renaming = file
        case .edit: edit(file)
        case .openInEditor: environments.openInEditor(file)
        case .showInFinder: environments.showInFinder(file)
        case .delete: environments.deletionCandidate = file
        }
    }

    private func rename(_ file: EnvironmentFile) {
        do {
            try environments.rename(file, to: newName)
        } catch {
            environments.actionError = .init(title: "Couldn't Rename “\(file.displayName)”", message: error.localizedDescription)
        }
    }

    /// Opens the file's options in the New Sandbox window, unless it has
    /// fields the window would drop when saving.
    private func edit(_ file: EnvironmentFile) {
        do {
            let text = try String(contentsOf: file.url, encoding: .utf8)
            let request = try CreateSandboxRequest(environmentFile: try EnvironmentYAML.parse(text), at: file.url)
            store.presentEdit(EnvironmentEdit(url: file.url, request: request))
        } catch {
            uneditable = Uneditable(file: file, reason: error.localizedDescription)
        }
    }
}

/// An environment file, with whether its sandbox exists, a button to create
/// it, and a menu of everything else.
private struct EnvironmentRow: View {
    enum Action {
        case create
        case runInTerminal
        case showSandbox
        case rename
        case edit
        case openInEditor
        case showInFinder
        case delete
    }

    let file: EnvironmentFile
    let sandbox: Sandbox?
    let perform: (Action) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.problem == nil ? "doc.text" : "exclamationmark.triangle")
                .foregroundStyle(file.problem == nil ? Color.secondary : Color.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.displayName)
                    if !file.isInLibrary {
                        Text("Opened")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: .capsule)
                            .help((file.url.path as NSString).abbreviatingWithTildeInPath)
                    }
                }
                Text(file.problem.map { "Couldn't read the file: \($0)" } ?? file.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            if let sandbox {
                HStack(spacing: 6) {
                    StatusDot(color: sandbox.state.color)
                    Text(sandbox.statusLabel)
                        .foregroundStyle(.secondary)
                }
                .help("A sandbox called “\(sandbox.name)” exists")
            } else if file.problem == nil {
                Button("Create…") { perform(.create) }
                    .help("Review what the file changes, then create its sandbox")
            }
            Menu {
                if sandbox != nil {
                    Button("Show Sandbox") { perform(.showSandbox) }
                } else {
                    Button("Create Sandbox…") { perform(.create) }
                        .disabled(file.problem != nil)
                }
                Button("Run in Terminal") { perform(.runInTerminal) }
                    .disabled(file.problem != nil)
                Divider()
                Button("Rename…") { perform(.rename) }
                    .disabled(file.problem != nil)
                Button("Edit…") { perform(.edit) }
                Button("Open in Editor") { perform(.openInEditor) }
                Button("Show in Finder") { perform(.showInFinder) }
                Divider()
                Button(file.isInLibrary ? "Delete…" : "Remove from List…", role: .destructive) { perform(.delete) }
            } label: {
                Label("More", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .contextMenu {
            Button("Create Sandbox…") { perform(.create) }
                .disabled(file.problem != nil || sandbox != nil)
            Button("Run in Terminal") { perform(.runInTerminal) }
                .disabled(file.problem != nil)
            Divider()
            Button("Rename…") { perform(.rename) }
                .disabled(file.problem != nil)
            Button("Edit…") { perform(.edit) }
            Button("Open in Editor") { perform(.openInEditor) }
            Button("Show in Finder") { perform(.showInFinder) }
        }
    }
}

@MainActor
enum EnvironmentFilePanel {
    /// Asks for an environment file and adds it to the list.
    @discardableResult
    static func open(into environments: EnvironmentStore) -> EnvironmentFile? {
        guard let url = OpenPanel.choose(
            files: [.yaml],
            showsHiddenFiles: true,
            prompt: "Open",
            message: "Choose an environment file, such as sbxenv.yaml."
        ).first else { return nil }
        return environments.open(url)
    }
}

// MARK: - Creating a sandbox from a file

/// Values for the file's arguments, then the plan sbx shows, then the output
/// of creating the sandbox once the plan is approved.
struct EnvironmentRunSheet: View {
    let run: EnvironmentRun
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var run = run

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                switch run.phase {
                case .arguments:
                    Form {
                        Section {
                            ForEach(run.file.arguments) { argument in
                                KitArgumentRow(argument: argument, isFixed: false, values: $run.argumentValues)
                            }
                        } footer: {
                            Text("The environment file declares these. Leave one empty to use its default.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .formStyle(.grouped)
                case .planning, .reviewing:
                    ConsoleOutputView(output: run.planOutput)
                    if run.phase == .reviewing {
                        reviewNotice
                    }
                case .creating, .succeeded:
                    ConsoleOutputView(output: run.createOutput)
                case .failed, .cancelled:
                    ConsoleOutputView(output: run.didPlan ? run.createOutput : run.planOutput)
                }
            }
            .padding(20)
            Divider()
            buttons
                .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 520)
        .interactiveDismissDisabled(run.phase == .planning || run.phase == .creating)
    }

    private var reviewNotice: some View {
        Label {
            Text(run.file.hasHostCommands
                ? "This file runs commands on your Mac with your permissions, listed in the plan. Only create it if you trust where the file came from."
                : "Creating the sandbox applies everything in the plan.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: run.file.hasHostCommands ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(run.file.hasHostCommands ? Color.orange : Color.secondary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var buttons: some View {
        HStack {
            if run.phase == .arguments, let message = run.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if run.phase != .arguments {
                Button("Copy Output", systemImage: "doc.on.doc") {
                    let output = run.didPlan && run.phase != .reviewing ? run.createOutput : run.planOutput
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output.text, forType: .string)
                }
            }
            Spacer()
            switch run.phase {
            case .arguments:
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Review Plan") { run.plan() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(run.validationMessage != nil)
            case .planning, .creating:
                Button("Cancel", role: .cancel) { run.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .reviewing:
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Sandbox") { run.create(onSuccess: onCreated) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            case .succeeded:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            case .failed, .cancelled:
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if run.didPlan || !run.file.arguments.isEmpty {
                    Button("Back") { run.back() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            switch run.phase {
            case .arguments:
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text("Create from “\(run.file.displayName)”")
            case .planning:
                ProgressView()
                    .controlSize(.small)
                Text("Reading the Plan…")
            case .reviewing:
                Image(systemName: "list.bullet.clipboard")
                    .foregroundStyle(.secondary)
                Text("Review the Plan for “\(run.file.displayName)”")
            case .creating:
                ProgressView()
                    .controlSize(.small)
                Text("Creating Sandbox…")
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Sandbox Created")
            case let .failed(message):
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(run.didPlan ? "Creation Failed" : "Couldn't Read the Plan")
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .cancelled:
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Cancelled")
            }
        }
        .font(.headline)
    }
}
