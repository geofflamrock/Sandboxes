import SwiftUI
import AppKit

struct CreateSandboxView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(RecentsStore.self) private var recents
    @Environment(\.dismiss) private var dismiss

    @State private var request = CreateSandboxRequest()
    @State private var run: CreationRun?

    var body: some View {
        Group {
            if let run {
                CreationOutputView(
                    run: run,
                    onBack: { self.run = nil },
                    onDone: { dismiss() }
                )
            } else {
                CreateSandboxForm(
                    request: $request,
                    onCancel: { dismiss() },
                    onCreate: start
                )
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 600)
        .interactiveDismissDisabled(run?.phase == .running)
        .onAppear {
            if request.workload.isEmpty, let last = recents.workloads.first {
                request.workload = last
            }
        }
    }

    private func start() {
        let request = request
        let run = CreationRun(request: request)
        run.start { [recents, store] in
            recents.record(workload: request.trimmedWorkload, kits: request.kits)
            Task { await store.refresh() }
        }
        self.run = run
    }
}

// MARK: - Form

private struct CreateSandboxForm: View {
    @Binding var request: CreateSandboxRequest
    let onCancel: () -> Void
    let onCreate: () -> Void

    @Environment(RecentsStore.self) private var recents
    @State private var newKit = ""
    @State private var isChoosingFolder = false

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Image", text: $request.workload, prompt: Text("docker/sbx-kit-claude"))
                        .font(.body.monospaced())
                    RecentsMenu(title: "Recent Workloads", items: recents.workloads) {
                        request.workload = $0
                    } onClear: {
                        recents.clearWorkloads()
                    }
                }
            } header: {
                Text("Workload")
            } footer: {
                Text("A v3 sandbox kit from an OCI registry.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(request.kits, id: \.self) { kit in
                    HStack {
                        Image(systemName: "puzzlepiece.extension")
                            .foregroundStyle(.secondary)
                        Text(kit)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle.fill") {
                            request.kits.removeAll { $0 == kit }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove kit")
                    }
                }
                HStack {
                    TextField("Add kit", text: $newKit, prompt: Text("ghcr.io/example/my-kit"))
                        .font(.body.monospaced())
                        .onSubmit(addTypedKit)
                    RecentsMenu(
                        title: "Recent Kits",
                        items: recents.kits.filter { !request.kits.contains($0) }
                    ) {
                        add(kit: $0)
                    } onClear: {
                        recents.clearKits()
                    }
                    Button("Add", action: addTypedKit)
                        .disabled(trimmedNewKit.isEmpty)
                }
            } header: {
                Text("Kits")
            } footer: {
                Text("Extra mixin kits from an OCI registry (v3 kits only).")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Folder") {
                    HStack {
                        if let workspace = request.workspace {
                            Label((workspace.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(workspace.path)
                            Button("Clear", systemImage: "xmark.circle.fill") {
                                request.workspace = nil
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Don't mount a workspace")
                        } else {
                            Text("None")
                                .foregroundStyle(.secondary)
                        }
                        Button("Choose…") { isChoosingFolder = true }
                    }
                }
                Picker("Mode", selection: $request.mode) {
                    ForEach(WorkspaceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(request.workspace == nil)
            } header: {
                Text("Workspace")
            } footer: {
                Text(request.workspace == nil
                     ? "Without a workspace the agent works in the sandbox's own filesystem."
                     : request.mode.explanation)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Name", text: $request.name, prompt: Text("Automatic"))
            } footer: {
                Text("Leave empty to let sbx choose a name.")
                    .foregroundStyle(.secondary)
            }

            Section("Command") {
                Text(commandPreview)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                request.workspace = url
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let message = request.validationMessage, !request.workload.isEmpty || !request.name.isEmpty {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(request.validationMessage != nil)
            }
            .controlSize(.large)
            .padding()
        }
    }

    private var trimmedNewKit: String {
        newKit.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The command as it will run, including a kit that's typed but not yet added.
    private var commandPreview: String {
        var preview = request
        if !trimmedNewKit.isEmpty && !preview.kits.contains(trimmedNewKit) {
            preview.kits.append(trimmedNewKit)
        }
        return preview.commandLine
    }

    private func addTypedKit() {
        add(kit: trimmedNewKit)
        newKit = ""
    }

    private func add(kit: String) {
        guard !kit.isEmpty, !request.kits.contains(kit) else { return }
        request.kits.append(kit)
    }

    private func create() {
        addTypedKit()
        onCreate()
    }
}

private struct RecentsMenu: View {
    let title: String
    let items: [String]
    let onSelect: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        Menu {
            Section(title) {
                ForEach(items, id: \.self) { item in
                    Button(item) { onSelect(item) }
                }
            }
            Divider()
            Button("Clear Recents", role: .destructive, action: onClear)
        } label: {
            Label(title, systemImage: "clock.arrow.circlepath")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(items.isEmpty)
        .help(title)
    }
}

// MARK: - Output

private struct CreationOutputView: View {
    let run: CreationRun
    let onBack: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(run.output.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator)
            }

            HStack {
                Button("Copy Output", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.output.text, forType: .string)
                }
                Spacer()
                switch run.phase {
                case .running:
                    Button("Cancel", role: .cancel) { run.cancel() }
                        .keyboardShortcut(.cancelAction)
                case .succeeded:
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                case .failed, .cancelled:
                    Button("Close", action: onDone)
                        .keyboardShortcut(.cancelAction)
                    Button("Edit Options", action: onBack)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(20)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            switch run.phase {
            case .running:
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
                Text("Creation Failed")
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
