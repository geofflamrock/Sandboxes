import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Management › Environment Files: files saved from the New Environment File
/// window or opened from elsewhere, with ways to create sandboxes from one,
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
                    Text(environments.hasLoaded ? "No environment files." : "Loading…")
                        .foregroundStyle(.secondary)
                }
                ForEach(environments.environments) { file in
                    EnvironmentRow(file: file, sandboxes: sandboxes(for: file)) { action in
                        perform(action, on: file)
                    }
                }
            } header: {
                Text("Environment Files")
            } footer: {
                Text("An environment file keeps a sandbox's agent, kits, workspace and settings, so you can create the same sandbox again, create several from it, or share it. New environment files are saved in \((EnvironmentStore.directory.path as NSString).abbreviatingWithTildeInPath). Creating a sandbox shows what the file changes on your Mac first, including any commands it runs here.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Environment Files")
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
                Button("New Environment File", systemImage: "plus") {
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
                ? "This changes the name in the file and its folder, and the name sandboxes created from it start with. Sandboxes already created keep their names."
                : "This changes the name in the file, which is the name sandboxes created from it start with. Sandboxes already created keep their names.")
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

    /// The sandboxes created from the file that still exist.
    private func sandboxes(for file: EnvironmentFile) -> [Sandbox] {
        let names = environments.sandboxNames(for: file)
        return store.sandboxes.filter { names.contains($0.name) }
    }

    private func perform(_ action: EnvironmentRow.Action, on file: EnvironmentFile) {
        switch action {
        case .create: environments.startCreating(from: file)
        case .runInTerminal: environments.runInTerminal(file)
        case let .showSandbox(id):
            store.selection = .sandbox(id)
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

/// An environment file, with the sandboxes created from it, a button to
/// create another, and a menu of everything else.
private struct EnvironmentRow: View {
    enum Action {
        case create
        case runInTerminal
        case showSandbox(Sandbox.ID)
        case rename
        case edit
        case openInEditor
        case showInFinder
        case delete
    }

    let file: EnvironmentFile
    let sandboxes: [Sandbox]
    let perform: (Action) -> Void


    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.problem == nil ? "square.stack.3d.up" : "exclamationmark.triangle")
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
            if let sandbox = sandboxes.first, sandboxes.count == 1 {
                HStack(spacing: 6) {
                    StatusDot(color: sandbox.state.color)
                    Text(sandbox.statusLabel)
                        .foregroundStyle(.secondary)
                }
                .help("“\(sandbox.name)” was created from this file")
            } else if !sandboxes.isEmpty {
                Text("\(sandboxes.count) Sandboxes")
                    .foregroundStyle(.secondary)
                    .help(sandboxes.map { "“\($0.name)”" }.formatted(.list(type: .and)) + " were created from this file")
            }
            if file.problem == nil {
                Button("Create…") { perform(.create) }
                    .help("Choose the sandbox's name and options, review what the file changes, then create it")
            }
            Menu {
                Button("Create Sandbox…") { perform(.create) }
                    .disabled(file.problem != nil)
                Button("Run in Terminal") { perform(.runInTerminal) }
                    .disabled(file.problem != nil)
                showSandboxButtons
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
                .disabled(file.problem != nil)
            Button("Run in Terminal") { perform(.runInTerminal) }
                .disabled(file.problem != nil)
            showSandboxButtons
            Divider()
            Button("Rename…") { perform(.rename) }
                .disabled(file.problem != nil)
            Button("Edit…") { perform(.edit) }
            Button("Open in Editor") { perform(.openInEditor) }
            Button("Show in Finder") { perform(.showInFinder) }
        }
    }

    @ViewBuilder
    private var showSandboxButtons: some View {
        if let sandbox = sandboxes.first, sandboxes.count == 1 {
            Button("Show Sandbox") { perform(.showSandbox(sandbox.id)) }
        } else if !sandboxes.isEmpty {
            Menu("Show Sandbox") {
                ForEach(sandboxes) { sandbox in
                    Button(sandbox.name) { perform(.showSandbox(sandbox.id)) }
                }
            }
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

/// The sandbox's name and the file's options, then the plan sbx shows, then
/// the output of creating the sandbox once the plan is approved.
struct EnvironmentRunSheet: View {
    let run: EnvironmentRun
    let onCreated: () -> Void
    @Environment(SandboxStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Why the options can't be used yet, including a name that's taken.
    private var validationMessage: String? {
        if let message = run.validationMessage {
            return message
        }
        if let name = run.sandboxName, store.sandboxes.contains(where: { $0.name == name }) {
            return "There's already a sandbox called “\(name)”. Enter another name."
        }
        return nil
    }

    var body: some View {
        @Bindable var run = run

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                switch run.phase {
                case .options:
                    EnvironmentRunOptions(run: run)
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
            if run.phase == .options, let message = validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if run.phase != .options {
                Button("Copy Output", systemImage: "doc.on.doc") {
                    let output = run.didPlan && run.phase != .reviewing ? run.createOutput : run.planOutput
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output.text, forType: .string)
                }
            }
            Spacer()
            switch run.phase {
            case .options:
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Review Plan") { run.plan() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(validationMessage != nil)
            case .planning, .creating:
                Button("Cancel", role: .cancel) { run.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .reviewing:
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Edit Options") { run.editOptions() }
                    .help("Change the name and options, then review a new plan")
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
                Button("Back") { run.back() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            switch run.phase {
            case .options:
                Image(systemName: "square.stack.3d.up")
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

/// What to create from the file: the sandbox's name, whether to add the
/// user's defaults, clone mode, and the file's arguments.
private struct EnvironmentRunOptions: View {
    let run: EnvironmentRun
    @AppStorage("environmentRunFileExpanded") private var isFileExpanded = false
    @AppStorage("environmentRunDefaultsExpanded") private var isDefaultsExpanded = false

    /// Whether the file, or the defaults added to it, use `${{ env.projectDir }}`.
    private var usesProjectDirectory: Bool {
        run.file.usesProjectDirectory
            || (run.usesDefaults && (run.defaults?.workspace(for: run.file) != nil || run.defaults?.usesProjectDirectoryElsewhere == true))
    }

    var body: some View {
        @Bindable var run = run

        Form {
            Section {
                EnvironmentFilePreview(url: run.file.url, text: run.fileText, isExpanded: $isFileExpanded)
            } header: {
                Text("Environment File")
            }

            Section {
                TextField("Name", text: $run.name, prompt: Text(run.sandboxName ?? "Automatic"))
            } footer: {
                Text(run.file.name?.isEmpty == false
                    ? "Starts as the name in the file. Enter another name to create another sandbox from it."
                    : "Leave empty to let sbx choose a name. Enter a name to create more than one sandbox from the file.")
                    .foregroundStyle(.secondary)
            }

            if run.defaults != nil {
                Section {
                    if run.canAddDefaults {
                        // Shown off when the defaults can't be added, whatever was chosen.
                        Toggle("Include My Defaults", isOn: Binding(
                            get: { run.usesDefaults },
                            set: { run.includesDefaults = $0 }
                        ))
                        .disabled(run.defaultsUnavailableReason != nil)
                        EnvironmentFilePreview(url: EnvironmentDefaults.url, text: run.defaultsText, isExpanded: $isDefaultsExpanded)
                    } else {
                        // There's no choice to make, so only say why.
                        Text(run.defaultsUnavailableReason ?? "")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Defaults")
                } footer: {
                    if run.canAddDefaults {
                        Text(run.defaultsUnavailableReason
                            ?? (run.usesDefaults
                                ? "sbx runs in the file's folder and adds the settings in ~/.sbxenv.yaml, as when you run it there yourself. The file's own settings win."
                                : "sbx is given the file, so only its own settings are used."))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if usesProjectDirectory {
                Section {
                    LabeledContent("Folder") {
                        Text((run.file.projectDirectory.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(run.file.projectDirectory.path)
                    }
                } header: {
                    Text("Project Directory")
                } footer: {
                    Text(run.file.isInLibrary
                        ? "The file uses ${{ env.projectDir }}, which sbx makes the folder the file is in. That's its folder in the environment files folder, not a project, so mount folders by their full paths instead."
                        : "${{ env.projectDir }} is the folder the file is in.")
                        .foregroundStyle(.secondary)
                }
            }

            if run.offersClone {
                Section {
                    Picker("Mode", selection: $run.mode) {
                        ForEach(WorkspaceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Workspace")
                } footer: {
                    Text(run.mode.explanation)
                        .foregroundStyle(.secondary)
                }
            }

            if !run.file.arguments.isEmpty {
                Section {
                    ForEach(run.file.arguments) { argument in
                        KitArgumentRow(argument: argument, isFixed: false, values: $run.argumentValues)
                    }
                } header: {
                    Text("Arguments")
                } footer: {
                    Text("The environment file declares these. Leave one empty to use its default.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A file the create sheet uses: its name and folder on one line, a link
/// to open it in an editor, and its YAML when expanded. Collapsed, the
/// options stay in view; the file is there to check what it does.
private struct EnvironmentFilePreview: View {
    let url: URL
    let text: String?
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                Text(text ?? "Couldn't read the file.")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 160)
            .background(.background.secondary, in: .rect(cornerRadius: 6))
        } label: {
            // One line: a long folder is cut short from the start, rather than wrapping.
            HStack(spacing: 8) {
                Label(url.lastPathComponent, systemImage: "doc.text")
                    .lineLimit(1)
                    .fixedSize()
                Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(url.path)
                Button("Open in Editor") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)
                .fixedSize()
            }
        }
    }
}
