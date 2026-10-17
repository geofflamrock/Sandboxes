import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 700)
        .interactiveDismissDisabled(run?.phase == .running)
        .onAppear {
            if request.workload.isEmpty {
                request.workload = store.createWorkload ?? recents.workloads.first ?? Agent.claude.workloadImage ?? ""
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
    @State private var kitDraft = KitDraft()
    @State private var tab = CreateSheetTab.general

    // The tab bar only style leaves out the bordered box the automatic style
    // draws around the content on macOS.
    var body: some View {
        TabView(selection: $tab) {
            ForEach(CreateSheetTab.allCases) { tab in
                Tab(tab.title, value: tab) {
                    Form {
                        switch tab {
                        case .general:
                            agentSection
                            nameSection
                            workspaceSection
                        case .kits:
                            kitsSection
                        case .runtime:
                            resourcesSection
                            environmentSection
                        }
                    }
                    .formStyle(.grouped)
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
        // The command and the buttons reflect every tab, so they stay in view whichever is open.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                commandSection
                actionBar
            }
            .padding()
        }
    }

    // MARK: Footer

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command")
                .font(.headline)
            Text(commandPreview)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.background.secondary, in: .rect(cornerRadius: 6))
        }
    }

    private var actionBar: some View {
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
    }

    // MARK: Agent

    private var agentSection: some View {
        Section {
            AgentPicker(selection: Agent(workloadImage: request.workload)) { agent in
                if let image = agent.workloadImage {
                    request.workload = image
                }
            }
            HStack {
                TextField("Image", text: $request.workload, prompt: Text("docker/sbx-kit-claude"))
                    .font(.body.monospaced())
                RecentsMenu(title: "Recent Images", items: recents.workloads) {
                    request.workload = $0
                } onClear: {
                    recents.clearWorkloads()
                }
            }
        } header: {
            Text("Agent")
        } footer: {
            Text("Pick an agent, or enter any v3 workload kit from an OCI registry.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Name

    private var nameSection: some View {
        Section {
            TextField("Name", text: $request.name, prompt: Text("Automatic"))
        } footer: {
            Text("Leave empty to let sbx choose a name.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Workspace

    private var workspaceSection: some View {
        Section {
            LabeledContent("Folder") {
                HStack {
                    if let workspace = request.workspace {
                        Label((workspace.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(workspace.path)
                        RemoveButton(help: "Don't mount a workspace") {
                            request.workspace = nil
                            request.additionalWorkspaces = []
                        }
                    } else {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }
                    Button("Choose…", action: chooseWorkspace)
                }
            }
            Picker("Mode", selection: $request.mode) {
                ForEach(WorkspaceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(request.workspace == nil)

            if request.workspace != nil {
                ForEach($request.additionalWorkspaces) { $folder in
                    HStack {
                        Label((folder.url.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder.badge.plus")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder.url.path)
                        Spacer()
                        Toggle("Read-only", isOn: $folder.isReadOnly)
                            .toggleStyle(.checkbox)
                            .help("Stop the agent changing anything in this folder")
                        RemoveButton(help: "Don't mount this folder") {
                            request.additionalWorkspaces.removeAll { $0.id == folder.id }
                        }
                    }
                }
                Button("Add Another Folder…", systemImage: "plus", action: addAdditionalWorkspaces)
                    .buttonStyle(.borderless)
            }
        } header: {
            Text("Workspace")
        } footer: {
            Text(workspaceFooter)
                .foregroundStyle(.secondary)
        }
    }

    private var workspaceFooter: String {
        guard request.workspace != nil else {
            return "Without a workspace the agent works in the sandbox's own filesystem."
        }
        if request.additionalWorkspaces.isEmpty {
            return request.mode.explanation
        }
        return request.mode.explanation + " Other folders are mounted at the same paths as on your Mac."
    }

    private func chooseWorkspace() {
        if let url = OpenPanel.choose(directories: true, prompt: "Choose", message: "Choose the folder the agent works in.").first {
            request.workspace = url
            request.additionalWorkspaces.removeAll { $0.url == url }
        }
    }

    private func addAdditionalWorkspaces() {
        let urls = OpenPanel.choose(
            directories: true,
            multiple: true,
            prompt: "Add",
            message: "Choose folders to mount alongside the workspace, such as docs or a related repository."
        )
        let existing = Set(request.additionalWorkspaces.map(\.url) + [request.workspace].compactMap { $0 })
        for url in urls where !existing.contains(url) {
            request.additionalWorkspaces.append(AdditionalWorkspace(url: url))
        }
    }

    // MARK: Kits

    private var kitsSection: some View {
        Section {
            ForEach(request.kits, id: \.self) { kit in
                HStack {
                    Image(systemName: KitSource(reference: kit).systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(KitSource(reference: kit) == .local ? (kit as NSString).abbreviatingWithTildeInPath : kit)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(kit)
                    Spacer()
                    RemoveButton(help: "Remove kit") {
                        request.kits.removeAll { $0 == kit }
                    }
                }
            }

            HStack {
                Picker("Add from", selection: $kitDraft.source) {
                    ForEach(KitSource.allCases) { source in
                        Label(source.title, systemImage: source.systemImage).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                RecentsMenu(
                    title: "Recent Kits",
                    items: recents.kits.filter { !request.kits.contains($0) }
                ) {
                    add(kit: $0)
                } onClear: {
                    recents.clearKits()
                }
            }

            switch kitDraft.source {
            case .registry:
                HStack {
                    TextField("Image", text: $kitDraft.image, prompt: Text("docker.io/example/my-kit:1.0"))
                        .font(.body.monospaced())
                        .onSubmit(addDraftKit)
                    Button("Add", action: addDraftKit)
                        .disabled(kitDraft.reference == nil)
                }
            case .git:
                TextField("Repository", text: $kitDraft.git.repository, prompt: Text("https://github.com/org/repo"))
                    .font(.body.monospaced())
                    .onSubmit(addDraftKit)
                TextField("Ref", text: $kitDraft.git.ref, prompt: Text("Default branch"))
                    .font(.body.monospaced())
                    .onSubmit(addDraftKit)
                TextField("Folder", text: $kitDraft.git.folder, prompt: Text("Repository root"))
                    .font(.body.monospaced())
                    .onSubmit(addDraftKit)
                HStack {
                    if !kitDraft.git.isEmpty {
                        Text(kitDraft.git.reference ?? "Enter the repository's URL.")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Add", action: addDraftKit)
                        .disabled(kitDraft.reference == nil)
                }
            case .local:
                LabeledContent("Folder or ZIP") {
                    Button("Choose…", action: chooseLocalKit)
                }
            }
        } footer: {
            Text(kitsFooter)
                .foregroundStyle(.secondary)
        }
    }

    private var kitsFooter: String {
        let intro = "Mixin kits add tools and settings to the agent."
        switch kitDraft.source {
        case .registry:
            return "\(intro) sbx only pulls kits from Docker Hub unless you allow other registries."
        case .git:
            return "\(intro) Paste a clone URL or a link to the kit's folder. Ref is a branch, tag or commit; Folder is where the kit is in the repository. sbx only uses Git kits if you allow Git sources."
        case .local:
            return "\(intro) sbx builds a kit folder or ZIP file on your Mac when it creates the sandbox."
        }
    }

    private func chooseLocalKit() {
        let urls = OpenPanel.choose(
            directories: true,
            files: [.zip],
            multiple: true,
            prompt: "Add",
            message: "Choose kit folders or ZIP files."
        )
        for url in urls {
            add(kit: url.path)
        }
    }

    private func addDraftKit() {
        guard let reference = kitDraft.reference else { return }
        add(kit: reference)
        kitDraft.clearFields()
    }

    private func add(kit: String) {
        guard !kit.isEmpty, !request.kits.contains(kit) else { return }
        request.kits.append(kit)
    }

    // MARK: Resources

    private var resourcesSection: some View {
        Section {
            Picker("CPUs", selection: $request.cpus) {
                Text("Automatic").tag(0)
                Divider()
                ForEach(1...HostResources.cpuCount, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            Picker("Memory", selection: $request.memoryGiB) {
                Text("Automatic").tag(0)
                Divider()
                ForEach(Self.memoryChoices, id: \.self) { size in
                    Text("\(size) GB").tag(size)
                }
            }
        } header: {
            Text("Resources")
        } footer: {
            Text("Automatic uses all \(HostResources.cpuCount) of your Mac's CPUs and \(Self.formattedMemory(HostResources.defaultMemoryGiB)) of memory.")
                .foregroundStyle(.secondary)
        }
    }

    private static let memoryChoices: [Int] = {
        let max = HostResources.maxMemoryGiB
        let sizes = [1, 2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256].filter { $0 < max }
        return sizes + [max]
    }()

    private static func formattedMemory(_ gib: Double) -> String {
        gib < 1 ? "512 MB" : "\(gib.formatted(.number.precision(.fractionLength(0...1)))) GB"
    }

    // MARK: Environment

    private var environmentSection: some View {
        Section {
            ForEach($request.environment) { $variable in
                HStack {
                    TextField("Name", text: $variable.key, prompt: Text("NAME"))
                        .labelsHidden()
                        .frame(maxWidth: 180)
                    Text("=")
                        .foregroundStyle(.secondary)
                    TextField("Value", text: $variable.value, prompt: Text("value"))
                        .labelsHidden()
                    RemoveButton(help: "Remove variable") {
                        request.environment.removeAll { $0.id == variable.id }
                    }
                }
                .font(.body.monospaced())
            }
            ForEach(request.environmentFiles, id: \.self) { file in
                HStack {
                    Label((file.path as NSString).abbreviatingWithTildeInPath, systemImage: "doc.text")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.path)
                    Spacer()
                    RemoveButton(help: "Remove file") {
                        request.environmentFiles.removeAll { $0 == file }
                    }
                }
            }
            HStack {
                Button("Add Variable", systemImage: "plus") {
                    request.environment.append(EnvironmentVariable())
                }
                Button("Add File…", systemImage: "doc.badge.plus", action: addEnvironmentFiles)
                Spacer()
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Environment")
        } footer: {
            Text("Set in the sandbox and saved with it, so store credentials as secrets instead. Variables entered here win over ones from files.")
                .foregroundStyle(.secondary)
        }
    }

    private func addEnvironmentFiles() {
        let urls = OpenPanel.choose(
            files: [.item],
            multiple: true,
            showsHiddenFiles: true,
            prompt: "Add",
            message: "Choose files of KEY=VALUE lines, such as a .env file."
        )
        for url in urls where !request.environmentFiles.contains(url) {
            request.environmentFiles.append(url)
        }
    }

    // MARK: Command

    /// The command as it will run, including a kit that's entered but not yet added.
    private var commandPreview: String {
        var preview = request
        if let pending = kitDraft.reference, !preview.kits.contains(pending) {
            preview.kits.append(pending)
        }
        return preview.commandLine
    }

    private func create() {
        addDraftKit()
        onCreate()
    }
}

private enum CreateSheetTab: CaseIterable, Identifiable {
    case general
    case kits
    case runtime

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .kits: "Kits"
        case .runtime: "Runtime"
        }
    }
}

/// What's typed into the kit fields before it's added.
private struct KitDraft {
    var source: KitSource = .registry
    var image = ""
    var git = GitKitDraft()

    var reference: String? {
        switch source {
        case .registry:
            let image = image.trimmingCharacters(in: .whitespacesAndNewlines)
            return image.isEmpty ? nil : image
        case .git:
            return git.reference
        case .local:
            return nil
        }
    }

    mutating func clearFields() {
        image = ""
        git = GitKitDraft()
    }
}

private struct RemoveButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button("Remove", systemImage: "minus.circle.fill", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(help)
    }
}

@MainActor
private enum OpenPanel {
    /// Shows an open panel and returns what was chosen, or nothing if it was cancelled.
    static func choose(
        directories: Bool = false,
        files: [UTType] = [],
        multiple: Bool = false,
        showsHiddenFiles: Bool = false,
        prompt: String,
        message: String
    ) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !files.isEmpty
        panel.allowedContentTypes = files
        panel.allowsMultipleSelection = multiple
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = showsHiddenFiles
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// A grid of agent tiles. The tile for the agent whose kit is in the image
/// field is highlighted; a custom image highlights none.
private struct AgentPicker: View {
    let selection: Agent?
    let onSelect: (Agent) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            ForEach(Agent.creatable, id: \.self) { agent in
                AgentTile(agent: agent, isSelected: agent == selection) {
                    onSelect(agent)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AgentTile: View {
    let agent: Agent
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                AgentIcon(agent: agent, size: 26, filled: true)
                    .foregroundStyle(agent.color ?? Color.primary)
                Text(agent.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(background, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                                  lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(agent.workloadImage ?? agent.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.15) }
        return isHovering ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.05)
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

    /// Briefly shows a checkmark after the approval command is copied.
    @State private var copiedCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ConsoleOutputView(output: run.output)

            if run.phase == .succeeded && run.withheldCredential {
                credentialNotice
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

    private var credentialNotice: some View {
        Label {
            VStack(alignment: .leading, spacing: 8) {
                Text("Approve the Kit’s Credentials")
                    .font(.headline)
                Text("The sandbox was created without a credential its kit uses, so signing in won’t work yet. sbx only asks to approve credentials when you create a sandbox in a terminal. Run this in one and approve the credential: it creates an empty sandbox you can remove afterwards. You only need to do this once on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(run.credentialApprovalCommandLine)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(run.credentialApprovalCommandLine, forType: .string)
                        copiedCommand = true
                    } label: {
                        Label(
                            copiedCommand ? "Copied" : "Copy Command",
                            systemImage: copiedCommand ? "checkmark" : "doc.on.doc"
                        )
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(copiedCommand ? Color.green : Color.secondary)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(copiedCommand ? "Copied" : "Copy Command")
                    .task(id: copiedCommand) {
                        guard copiedCommand else { return }
                        try? await Task.sleep(for: .seconds(2))
                        copiedCommand = false
                    }
                }
                .padding(8)
                .background(.background.secondary, in: .rect(cornerRadius: 6))
            }
        } icon: {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 10))
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
