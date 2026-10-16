import SwiftUI
import AppKit

/// Shows what a saved environment sets up and creates a sandbox from it with
/// `sbx env create`.
struct CreateFromEnvironmentView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var request: EnvironmentCreateRequest
    @State private var run: CreationRun?

    init(environment: SandboxEnvironment) {
        _request = State(initialValue: EnvironmentCreateRequest(environment: environment))
    }

    var body: some View {
        Group {
            if let run {
                CreationOutputView(
                    run: run,
                    onBack: { self.run = nil },
                    onDone: { dismiss() }
                )
            } else {
                EnvironmentForm(
                    request: $request,
                    onCancel: { dismiss() },
                    onCreate: start
                )
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 660)
        .interactiveDismissDisabled(run?.phase == .running)
    }

    private func start() {
        let run = CreationRun(arguments: request.arguments, commandLine: request.commandLine)
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
                let argument = definition?.args?[key]
                let value = Binding(
                    get: { request.argumentValues[key] ?? "" },
                    set: { request.argumentValues[key] = $0 }
                )
                if let choices = argument?.choices, !choices.isEmpty {
                    Picker(key, selection: value) {
                        if argument?.required == true && !choices.contains(value.wrappedValue) {
                            Text("Choose").tag(value.wrappedValue)
                        }
                        ForEach(choices, id: \.self) { Text($0).tag($0) }
                    }
                    .help(argument?.description ?? "")
                } else {
                    TextField(key, text: value, prompt: Text(argument?.required == true ? "Required" : ""))
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
            ForEach(Array((definition.additionalWorkspaces ?? []).enumerated()), id: \.offset) { _, mount in
                LabeledContent(mount.readOnly == true ? "Read-only folder" : "Folder") {
                    pathLabel(mount.path, systemImage: "folder.badge.plus")
                }
            }
            if let kits = definition.kits, !kits.isEmpty {
                LabeledContent("Kits") {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(kits.map(\.source), id: \.self) { kit in
                            Label(kit, systemImage: KitSource(reference: kit).systemImage)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(kit)
                        }
                    }
                }
            }
            if let env = definition.env, !env.isEmpty {
                LabeledContent("Variables") {
                    Text(env.keys.sorted().joined(separator: ", "))
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.trailing)
                }
            }
            if let options = definition.sandboxOptions, options.cpus != nil || options.memory != nil {
                LabeledContent("Resources") {
                    Text([options.cpus.map { "\($0) CPUs" }, options.memory].compactMap { $0 }.joined(separator: ", "))
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
    private var hostCommands: [(label: String, command: String)] {
        guard let definition else { return [] }
        var commands: [(label: String, command: String)] = []
        for (name, secret) in (definition.secrets ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let command = secret.command {
                commands.append(("Secret \(name)", command))
            }
        }
        for phase in ["initialize", "postCreate"] {
            for hook in definition.lifecycle?[phase] ?? [] {
                commands.append((hook.name ?? phase, hook.command))
            }
        }
        return commands
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
