import SwiftUI
import AppKit

/// The New Sandbox from Environment window: shows what a saved environment
/// sets up and creates a sandbox from it with `sbx env create`.
struct CreateFromEnvironmentView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var request: EnvironmentCreateRequest?
    @State private var run: CreationRun?

    var body: some View {
        Group {
            if let run {
                CreationOutputView(
                    run: run,
                    onBack: { self.run = nil },
                    onDone: close
                )
            } else if let request = Binding($request) {
                EnvironmentForm(
                    request: request,
                    onCancel: close,
                    onCreate: start
                )
            } else {
                ContentUnavailableView(
                    "No Environment",
                    systemImage: "square.stack.3d.up",
                    description: Text("Choose an environment on the home page to create a sandbox from it.")
                )
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 660)
        .navigationTitle(request.map { "New Sandbox from “\($0.environment.name)”" } ?? "New Sandbox from Environment")
        .windowDismissBehavior(run?.phase == .running ? .disabled : .automatic)
        .background(WindowReader(kind: .createFromEnvironment))
        // Asked again while the window is open, such as for another
        // environment: show that one, read afresh, unless a sandbox is being created.
        .onChange(of: store.environmentRequests, initial: true) {
            guard run?.phase != .running else { return }
            run = nil
            request = store.environmentToCreate.map { EnvironmentCreateRequest(environment: SandboxEnvironment(fileURL: $0.fileURL)) }
        }
        // Start afresh the next time the window opens.
        .onDisappear {
            run = nil
        }
    }

    private func close() {
        dismissWindow(id: AppWindows.createFromEnvironmentID)
    }

    private func start() {
        guard let request else { return }
        let run = CreationRun(request: request)
        run.start { [store] in
            Task { await store.refresh() }
        }
        self.run = run
    }
}

private struct EnvironmentForm: View {
    @Binding var request: EnvironmentCreateRequest
    let onCancel: () -> Void
    let onCreate: () -> Void

    @Environment(SandboxStore.self) private var store
    @State private var showsFile = false

    private var environment: SandboxEnvironment { request.environment }
    private var definition: SandboxEnvironment.Definition? { environment.definition }

    var body: some View {
        Form {
            header

            if let error = environment.readError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } footer: {
                    Text("The app couldn't read this file, but sbx may still be able to. Check the file below.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                TextField("Name", text: $request.name, prompt: Text(definition?.name ?? "Automatic"))
            } footer: {
                Text(definition?.name == nil
                     ? "Leave empty to let sbx choose a name."
                     : "Leave empty to use the name in the environment.")
                    .foregroundStyle(.secondary)
            }

            if !request.argumentNames.isEmpty {
                argumentsSection
            }
            if let definition {
                setupSection(definition)
            }
            if !hostCommands.isEmpty {
                hostCommandsSection
            }

            Section {
                DisclosureGroup("sbxenv.yaml", isExpanded: $showsFile) {
                    Text(environment.contents)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("File")
            }

            Section("Command") {
                Text(request.commandLine)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(validationMessage != nil)
            }
            .controlSize(.large)
            .padding()
        }
    }

    private var validationMessage: String? {
        if let message = request.validationMessage {
            return message
        }
        // Creating would fail on the name, so say so before it's tried.
        let name = request.trimmedName.isEmpty ? definition?.name : request.trimmedName
        if let name, store.sandboxes.contains(where: { $0.name == name }) {
            return "There's already a sandbox named “\(name)”. Enter another name."
        }
        return nil
    }

    // MARK: Header

    private var header: some View {
        Section {
            HStack(spacing: 12) {
                AgentIcon(agent: environment.agent, size: 26, filled: true)
                    .foregroundStyle(environment.agent?.color ?? Color.primary)
                    .frame(width: 48, height: 48)
                    .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(environment.name)
                        .font(.title3.weight(.semibold))
                    Text((environment.fileURL.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(environment.fileURL.path)
                }
                Spacer()
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([environment.fileURL])
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Show in Finder")
                Button("Open File", systemImage: "square.and.pencil") {
                    NSWorkspace.shared.open(environment.fileURL)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Open the file to edit it")
            }
        }
    }

    // MARK: Arguments

    private var argumentsSection: some View {
        Section {
            ForEach(request.argumentNames, id: \.self) { key in
                let argument = definition?.args[key]
                let value = Binding(
                    get: { request.argumentValues[key] ?? "" },
                    set: { request.argumentValues[key] = $0 }
                )
                if let choices = argument?.choices, !choices.isEmpty {
                    Picker(key, selection: value) {
                        if argument?.isRequired == true && !choices.contains(value.wrappedValue) {
                            Text("Choose").tag(value.wrappedValue)
                        }
                        ForEach(choices, id: \.self) { Text($0).tag($0) }
                    }
                    .help(argument?.description ?? "")
                } else {
                    TextField(key, text: value, prompt: Text(argument?.isRequired == true ? "Required" : ""))
                        .help(argument?.description ?? "")
                }
            }
        } header: {
            Text("Arguments")
        } footer: {
            Text("Values the environment uses. Only ones you change are passed to sbx.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Setup

    private func setupSection(_ definition: SandboxEnvironment.Definition) -> some View {
        Section("Setup") {
            LabeledContent("Agent") {
                Text(environment.agent?.displayName ?? definition.agent ?? "Not set")
                    .help(definition.agent ?? "")
            }
            LabeledContent("Workspace") {
                if let workspace = definition.workspace {
                    HStack(spacing: 6) {
                        pathLabel(workspace.path, systemImage: "folder")
                        if workspace.clone {
                            Text("Clone")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: .capsule)
                        }
                    }
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
            }
            ForEach(Array(definition.additionalWorkspaces.enumerated()), id: \.offset) { _, mount in
                LabeledContent(mount.readOnly ? "Read-only Folder" : "Folder") {
                    pathLabel(mount.path, systemImage: "folder.badge.plus")
                }
            }
            if !definition.kits.isEmpty {
                LabeledContent("Kits") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(Array(definition.kits.enumerated()), id: \.offset) { _, kit in
                            VStack(alignment: .trailing, spacing: 1) {
                                Label(kit.source, systemImage: KitSource(reference: kit.source).systemImage)
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(kit.source)
                                ForEach(kit.args.sorted { $0.key < $1.key }, id: \.key) { name, value in
                                    Text("\(name) = \(value)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    }
                }
            }
            if !definition.env.isEmpty {
                LabeledContent("Variables") {
                    Text(definition.env.keys.sorted().joined(separator: ", "))
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.trailing)
                }
            }
            if definition.cpus != nil || definition.memory != nil {
                LabeledContent("Resources") {
                    Text([definition.cpus.map { "\($0) CPUs" }, definition.memory].compactMap { $0 }.joined(separator: ", "))
                }
            }
        }
    }

    private func pathLabel(_ path: String, systemImage: String) -> some View {
        let url = environment.resolve(path)
        return Label((url.path as NSString).abbreviatingWithTildeInPath, systemImage: systemImage)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(url.path)
    }

    // MARK: Host commands

    /// Commands sbx runs on the Mac rather than in the sandbox: secrets read
    /// from a command, and lifecycle hooks.
    private var hostCommands: [SandboxEnvironment.HostCommand] {
        definition?.hostCommands ?? []
    }

    private var hostCommandsSection: some View {
        Section {
            ForEach(Array(hostCommands.enumerated()), id: \.offset) { _, item in
                LabeledContent(item.label) {
                    Text(item.command)
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Runs on Your Mac")
        } footer: {
            Text("Creating the sandbox runs these commands on your Mac, outside the sandbox. Only create it if you trust this environment.")
                .foregroundStyle(.secondary)
        }
    }
}
