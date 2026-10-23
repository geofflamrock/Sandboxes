import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CreateSandboxView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(RecentsStore.self) private var recents
    @Environment(EnvironmentStore.self) private var environments
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(AgentVersion.key) private var agentVersion = AgentVersion.kit

    @State private var request = CreateSandboxRequest()
    @State private var run: CreationRun?
    /// The environment file being edited, which Save writes back to.
    @State private var editingURL: URL?
    @State private var saveError: String?
    /// Counts what the window has been opened or asked for, so the form starts
    /// on General each time. The window keeps its views while it's closed.
    @State private var presentation = 0
    /// Kits already inspected stay known while the window is open, so going
    /// back to edit options doesn't read them again.
    @State private var inspector = KitInspector()

    var body: some View {
        Group {
            if let run {
                CreationOutputView(
                    run: run,
                    onBack: { self.run = nil },
                    onDone: close
                )
            } else {
                CreateSandboxForm(
                    request: $request,
                    inspector: inspector,
                    presentation: presentation,
                    editingURL: editingURL,
                    saveError: saveError,
                    onCancel: close,
                    onCreate: start,
                    onSave: save
                )
            }
        }
        .navigationTitle(title)
        .frame(minWidth: 740, idealWidth: 820, minHeight: 560, idealHeight: 700)
        .windowDismissBehavior(run?.phase == .running ? .disabled : .automatic)
        .background(WindowReader(kind: .create))
        .onAppear(perform: applyPreset)
        // Asked again while the window is open, such as from an agent on the
        // home page: switch to what was asked for unless a sandbox is being created.
        .onChange(of: store.createRequests) {
            if run == nil {
                applyPreset()
            }
        }
        .onChange(of: request.name) {
            saveError = nil
        }
        // Start afresh the next time the window opens.
        .onDisappear {
            request = CreateSandboxRequest()
            run = nil
            editingURL = nil
            saveError = nil
        }
    }

    private var title: String {
        if let editingURL {
            return "Edit “\(EnvironmentFile.fallbackName(for: editingURL))”"
        }
        return request.target == .environment ? "New Environment File" : "New Sandbox"
    }

    /// Starts with what the window was opened for: an environment file to
    /// edit, or a new sandbox or environment file with the workload asked for.
    private func applyPreset() {
        saveError = nil
        presentation += 1
        if let edit = store.environmentEdit {
            request = edit.request
            editingURL = edit.url
            return
        }
        if editingURL != nil {
            request = CreateSandboxRequest()
            editingURL = nil
        }
        request.target = store.createTarget
        if let workload = store.createWorkload {
            request.workload = workload
        } else if request.workload.isEmpty {
            request.workload = recents.workloads.first ?? Agent.claude.workload(for: agentVersion) ?? ""
        }
    }

    /// Writes the environment file, then shows it in Management › Environment Files.
    private func save() {
        do {
            try environments.save(request, to: editingURL)
            recents.record(workload: request.trimmedWorkload, kits: request.kits)
            store.selection = .environments
            close()
            AppWindows.showMain()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func close() {
        dismissWindow(id: AppWindows.createID)
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
    let inspector: KitInspector
    let presentation: Int
    /// The environment file being edited, which can't turn into a sandbox.
    let editingURL: URL?
    let saveError: String?
    let onCancel: () -> Void
    let onCreate: () -> Void
    let onSave: () -> Void

    @Environment(RecentsStore.self) private var recents
    @AppStorage(AgentVersion.key) private var agentVersion = AgentVersion.kit
    @Environment(MCPServerStore.self) private var mcp
    @State private var kitDraft = KitDraft()
    @State private var section = CreateSandboxSection.general
    /// Sections visited before and after the current one, for Back and Forward.
    @State private var backSections: [CreateSandboxSection] = []
    @State private var forwardSections: [CreateSandboxSection] = []
    @AppStorage("environmentFilePreviewExpanded") private var isFilePreviewExpanded = false

    private var isEditing: Bool { editingURL != nil }

    var body: some View {
        NavigationSplitView {
            // Clicking below the rows sets nil, which is ignored so a section always shows.
            List(selection: Binding {
                Optional(section)
            } set: { selected in
                if let selected {
                    show(selected)
                }
            }) {
                ForEach(visibleSections) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .badge(badge(for: section))
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            // The command and the buttons reflect every section, so they stay in view
            // whichever is open. They sit below the form rather than in a safe area bar,
            // which drew their text upside down after switching between a sandbox and
            // an environment file.
            VStack(spacing: 0) {
                form
                VStack(alignment: .leading, spacing: 12) {
                    commandSection
                    actionBar
                }
                .padding()
            }
            // As in System Settings, the title is the section, after Back and Forward.
            .navigationTitle(section.title)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left", action: goBack)
                        .disabled(backSections.isEmpty)
                        .keyboardShortcut("[")
                        .help("See the section you were on before")
                    Button("Forward", systemImage: "chevron.right", action: goForward)
                        .disabled(forwardSections.isEmpty)
                        .keyboardShortcut("]")
                        .help("See the section you went back from")
                }
            }
        }
        .onChange(of: presentation) {
            section = .general
            backSections.removeAll()
            forwardSections.removeAll()
        }
        .onChange(of: request.target) {
            let visible = visibleSections
            backSections.removeAll { !visible.contains($0) }
            forwardSections.removeAll { !visible.contains($0) }
            if !visible.contains(section) {
                section = .general
            }
        }
        .task {
            await mcp.refresh()
        }
        // A typed workload is inspected once typing pauses, rather than for
        // every partial reference. Docker's own agents are inspected straight away.
        .task(id: request.trimmedWorkload) {
            let workload = request.trimmedWorkload
            guard KitArgument.isInspectable(workload: workload) else { return }
            if inspector.results[workload] == nil && Agent.match(workload: workload) == nil {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
            }
            inspector.inspect(workload)
        }
        .onChange(of: request.kits, initial: true) {
            for kit in request.kits {
                inspector.inspect(kit)
            }
        }
        .onChange(of: request.argumentKits, initial: true, syncDeclaredArguments)
        .onChange(of: inspector.results, syncDeclaredArguments)
    }

    private var form: some View {
        Form {
            switch section {
            case .general:
                nameSection
                agentSection
                if KitArgument.isInspectable(workload: request.trimmedWorkload) {
                    kitArgumentsSection(for: request.trimmedWorkload)
                }
            case .workspace:
                workspaceSection
                if request.workspace != nil {
                    additionalWorkspacesSection
                }
            case .kits:
                kitsSection
                if !availableRecentKits.isEmpty {
                    recentKitsSection
                }
                ForEach(request.kits, id: \.self) { kit in
                    kitArgumentsSection(for: kit) {
                        request.kits.removeAll { $0 == kit }
                        request.kitArgumentValues[kit] = nil
                    }
                }
            case .runtime:
                resourcesSection
                environmentSection
            case .network:
                deniedHostsSection
            case .mcp:
                mcpSection
            }
        }
        .formStyle(.grouped)
        // The form fades where it meets the command, as it did scrolling under it.
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    private func show(_ next: CreateSandboxSection) {
        guard next != section else { return }
        backSections.append(section)
        forwardSections.removeAll()
        section = next
    }

    private func goBack() {
        guard let previous = backSections.popLast() else { return }
        forwardSections.append(section)
        section = previous
    }

    private func goForward() {
        guard let next = forwardSections.popLast() else { return }
        backSections.append(section)
        section = next
    }

    /// The sections for what's being made. An environment file doesn't pick MCP
    /// servers the way `sbx create` does: it registers servers itself. It has
    /// no network rules either.
    private var visibleSections: [CreateSandboxSection] {
        request.target == .environment
            ? CreateSandboxSection.allCases.filter { $0 != .mcp && $0 != .network }
            : CreateSandboxSection.allCases
    }

    /// How many things are added in a section, so what's set elsewhere shows
    /// without opening it. A zero badge isn't shown.
    private func badge(for section: CreateSandboxSection) -> Int {
        switch section {
        case .kits: request.kits.count
        case .network: request.deniedHostList.count
        case .mcp: request.staticMCPServers.count
        case .general, .workspace, .runtime: 0
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var commandSection: some View {
        switch request.target {
        case .sandbox:
            VStack(alignment: .leading, spacing: 6) {
                Text("Command")
                    .font(.headline)
                Text(previewRequest.commandLine)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.background.secondary, in: .rect(cornerRadius: 6))
            }
        case .environment:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    // Collapsed, the window shows more of the form; the file is only a preview.
                    Button {
                        withAnimation(.snappy) { isFilePreviewExpanded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isFilePreviewExpanded ? 90 : 0))
                            Text("Environment File")
                                .font(.headline)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(isFilePreviewExpanded ? "Hide the file" : "Show the file")
                    Spacer()
                    if let filePath {
                        Text(filePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                            .help(filePath)
                    }
                }
                if isFilePreviewExpanded {
                    ScrollView {
                        Text(previewRequest.environmentFileText)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 140)
                    .background(.background.secondary, in: .rect(cornerRadius: 6))
                }
            }
        }
    }

    /// The file being edited, or where Save puts a new environment once it has a name.
    private var filePath: String? {
        let url: URL
        if let editingURL {
            url = editingURL
        } else if !request.trimmedName.isEmpty {
            url = EnvironmentStore.directory
                .appendingPathComponent(request.trimmedName, isDirectory: true)
                .appendingPathComponent(EnvironmentStore.fileName)
        } else {
            return nil
        }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    private var actionBar: some View {
        HStack {
            if let message = saveError ?? request.validationMessage, saveError != nil || !request.workload.isEmpty || !request.name.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(request.target == .environment ? "Save" : "Create", action: create)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(request.validationMessage != nil)
        }
        .controlSize(.large)
    }

    // MARK: Agent

    private var agentSection: some View {
        Section {
            Picker("Version", selection: $agentVersion) {
                ForEach(AgentVersion.allCases) { version in
                    Text(version.title).tag(version)
                }
            }
            .pickerStyle(.segmented)
            AgentPicker(
                agents: Agent.creatable(in: agentVersion),
                version: agentVersion,
                selection: Agent(workload: request.workload)
            ) { agent in
                if let workload = agent.workload(for: agentVersion) {
                    request.workload = workload
                }
            }
            HStack {
                TextField(
                    agentVersion == .builtIn ? "Agent" : "Image",
                    text: $request.workload,
                    prompt: Text(Agent.claude.workload(for: agentVersion) ?? "")
                )
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
            Text(agentFooter)
                .foregroundStyle(.secondary)
        }
        // Switching version swaps a picked agent for the same agent in the other version.
        .onChange(of: agentVersion) {
            if let agent = Agent(workload: request.workload), let workload = agent.workload(for: agentVersion) {
                request.workload = workload
            }
        }
        // Picking a recent image or typing one of Docker's agents shows its version.
        .onChange(of: request.workload, initial: true) {
            if let version = Agent.match(workload: request.workload)?.version {
                agentVersion = version
            }
        }
    }

    private var agentFooter: String {
        switch agentVersion {
        case .builtIn: "Built-in agents come with sbx. Pick one, or enter a workload kit from an OCI registry."
        case .kit: "Pick an agent, or enter any workload kit from an OCI registry."
        }
    }

    // MARK: Name

    private var nameSection: some View {
        Section {
            TextField("Name", text: $request.name, prompt: Text(request.target == .environment ? "Required" : "Automatic"))
                .disabled(isEditing)
        } footer: {
            Text(isEditing ? "Rename the environment file from Management › Environment Files." : nameFooter)
                .foregroundStyle(.secondary)
        }
    }

    private var nameFooter: String {
        switch request.target {
        case .sandbox: "Leave empty to let sbx choose a name."
        case .environment: "Names the environment file, and the sandboxes created from it unless they're given another name."
        }
    }

    // MARK: Workspace

    private var workspaceSection: some View {
        Section {
            LabeledContent("Folder") {
                WorkspacePathField(
                    path: $request.workspacePath,
                    prompt: "None",
                    panelMessage: "Choose the folder the agent works in."
                ) { url in
                    request.additionalWorkspaces.removeAll { $0.normalizedPath == url.path }
                }
            }
            Picker("Mode", selection: $request.mode) {
                ForEach(WorkspaceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(request.workspace == nil)
        } footer: {
            Text(workspaceFooter)
                .foregroundStyle(.secondary)
        }
    }

    private var workspaceFooter: String {
        guard request.workspace != nil else {
            return "Without a workspace the agent works in the sandbox's own filesystem."
        }
        return request.mode.explanation
    }

    private var additionalWorkspacesSection: some View {
        Section {
            ForEach($request.additionalWorkspaces) { $folder in
                HStack {
                    WorkspacePathField(
                        path: $folder.path,
                        prompt: "~/src/docs",
                        panelMessage: "Choose a folder to mount alongside the workspace."
                    )
                    Toggle("Read-only", isOn: $folder.isReadOnly)
                        .toggleStyle(.checkbox)
                        .help("Stop the agent changing anything in this folder")
                    RemoveButton(help: "Don't mount this folder") {
                        request.additionalWorkspaces.removeAll { $0.id == folder.id }
                    }
                }
            }
            // A new row is empty: type its path or choose the folder.
            Button("Add", systemImage: "plus") {
                request.additionalWorkspaces.append(AdditionalWorkspace())
            }
            .buttonStyle(.borderless)
            .help("Add a folder to mount")
        } header: {
            Text("Additional Folders")
        } footer: {
            Text("These folders are mounted at the same paths as on your Mac.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Kits

    private var kitsSection: some View {
        Section {
            Picker("Add from", selection: $kitDraft.source) {
                ForEach(KitSource.allCases) { source in
                    Label(source.title, systemImage: source.systemImage).tag(source)
                }
            }
            .pickerStyle(.segmented)

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

    // MARK: Recent kits

    /// Recent kits that aren't added already, so a card can't add a kit
    /// twice, which sbx refuses.
    private var availableRecentKits: [String] {
        recents.kits.filter { !request.kits.contains($0) }
    }

    /// Cards for the most recent kits, so one used before is a click away.
    /// Older ones are in the More menu rather than pushing the added kits
    /// further down.
    private var recentKitsSection: some View {
        let kits = availableRecentKits
        let shown = kits.prefix(Self.recentKitCardLimit)
        let more = kits.dropFirst(Self.recentKitCardLimit)
        return Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                ForEach(Array(shown), id: \.self) { kit in
                    RecentKitCard(kit: kit) { add(kit: kit) }
                }
            }
            .padding(.vertical, 4)
        } header: {
            HStack {
                Text("Recent Kits")
                Spacer()
                if !more.isEmpty {
                    Menu("More") {
                        ForEach(Array(more), id: \.self) { kit in
                            Button(kit) { add(kit: kit) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button("Clear") { recents.clearKits() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private static let recentKitCardLimit = 6

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

    // MARK: Kit arguments

    private func kitArgumentsSection(for kit: String, onRemove: (() -> Void)? = nil) -> some View {
        KitArgumentsSection(
            kit: kit,
            result: inspector.results[kit],
            values: Binding {
                request.kitArgumentValues[kit] ?? [:]
            } set: {
                request.kitArgumentValues[kit] = $0
            },
            onRetry: { inspector.inspect(kit) },
            onRemove: onRemove
        )
    }

    /// Copies what inspecting the picked kits found into the request, which
    /// needs it to check values and build the command.
    private func syncDeclaredArguments() {
        for kit in request.argumentKits {
            if case let .loaded(inspection) = inspector.results[kit],
               request.declaredKitArguments[kit] != inspection.arguments {
                request.setDeclaredArguments(inspection.arguments, for: kit)
            }
        }
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
            ForEach(request.target == .sandbox ? request.environmentFiles : [], id: \.self) { file in
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
                // An environment file can't read variables from other files.
                if request.target == .sandbox {
                    Button("Add File…", systemImage: "doc.badge.plus", action: addEnvironmentFiles)
                }
                Spacer()
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Environment")
        } footer: {
            Text(request.target == .sandbox
                ? "Set in the sandbox and saved with it, so store credentials as secrets instead. Variables entered here win over ones from files."
                : "Set in the sandbox and saved in the environment file, so store credentials as secrets instead.")
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

    // MARK: Network

    // A text field's Return creates the sandbox, so hosts go in an editor,
    // one per line.
    private var deniedHostsSection: some View {
        Section {
            TextEditor(text: $request.deniedHosts)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .frame(minHeight: 88)
                .overlay(alignment: .topLeading) {
                    if request.deniedHosts.isEmpty {
                        Text("api.example.com\n*.example.com")
                            .font(.body.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Blocked Hosts")
        } header: {
            Text("Blocked Hosts")
        } footer: {
            Text("Blocked for this sandbox only, even where another rule allows them. You can change or remove these later in the sandbox's Policies tab.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: MCP

    private var mcpSection: some View {
        Section {
            if mcp.servers.isEmpty {
                Text(mcp.hasLoaded ? "No MCP servers are registered. Add them in Management › MCP Servers." : "Loading…")
                    .foregroundStyle(.secondary)
            }
            ForEach(mcp.servers) { server in
                Toggle(isOn: mcpBinding(for: server.name)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                        Text(server.status == .ready ? server.transportTitle : "\(server.transportTitle) · \(server.statusTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        } header: {
            Text("MCP Servers")
        } footer: {
            Text(request.staticMCPServers.isEmpty
                ? "With none chosen, the agent can find and load registered servers itself."
                : "Only these servers are loaded, and the agent can't find others itself. You can still load more into the sandbox later.")
                .foregroundStyle(.secondary)
        }
    }

    private func mcpBinding(for name: String) -> Binding<Bool> {
        Binding {
            request.staticMCPServers.contains(name)
        } set: { isOn in
            if isOn {
                if !request.staticMCPServers.contains(name) {
                    request.staticMCPServers.append(name)
                }
            } else {
                request.staticMCPServers.removeAll { $0 == name }
            }
        }
    }

    // MARK: Command

    /// The request as it will run or be saved, including a kit that's
    /// entered but not yet added.
    private var previewRequest: CreateSandboxRequest {
        var preview = request
        if let pending = kitDraft.reference, !preview.kits.contains(pending) {
            preview.kits.append(pending)
        }
        return preview
    }

    private func create() {
        addDraftKit()
        switch request.target {
        case .sandbox: onCreate()
        case .environment: onSave()
        }
    }
}

private enum CreateSandboxSection: CaseIterable, Identifiable {
    case general
    case workspace
    case kits
    case runtime
    case network
    case mcp

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .workspace: "Workspace"
        case .kits: "Kits"
        case .runtime: "Runtime"
        case .network: "Network"
        case .mcp: "MCP"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .workspace: "folder"
        case .kits: "shippingbox"
        case .runtime: "cpu"
        case .network: "network"
        case .mcp: "puzzlepiece.extension"
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

/// A folder's path, typed or chosen in an open panel.
private struct WorkspacePathField: View {
    @Binding var path: String
    let prompt: String
    let panelMessage: String
    var onChoose: (URL) -> Void = { _ in }

    var body: some View {
        HStack {
            TextField("Folder", text: $path, prompt: Text(prompt))
                .labelsHidden()
                .font(.body.monospaced())
                .help(path)
            Button("Choose…") {
                if let url = OpenPanel.choose(directories: true, prompt: "Choose", message: panelMessage).first {
                    path = url.path
                    onChoose(url)
                }
            }
        }
    }
}

struct RemoveButton: View {
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
enum OpenPanel {
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

/// A grid of agent tiles. The tile for the agent in the image field is
/// highlighted; a custom image highlights none.
private struct AgentPicker: View {
    let agents: [Agent]
    let version: AgentVersion
    let selection: Agent?
    let onSelect: (Agent) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            ForEach(agents, id: \.self) { agent in
                AgentTile(agent: agent, workload: agent.workload(for: version), isSelected: agent == selection) {
                    onSelect(agent)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AgentTile: View {
    let agent: Agent
    let workload: String?
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
        .help(workload ?? agent.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.15) }
        return isHovering ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.05)
    }
}

/// A kit used before, by its short name and where it's from, which adds it
/// when clicked.
private struct RecentKitCard: View {
    let kit: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let source = KitSource(reference: kit)
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: source.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(KitArgument.handle(for: kit))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(source == .local ? (kit as NSString).abbreviatingWithTildeInPath : kit)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(isHovering ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.05), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Add “\(kit)”")
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
