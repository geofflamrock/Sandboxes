import SwiftUI

/// Management › MCP Servers: the servers registered with sbx, with ways to
/// add, authorise, inspect, load and remove them.
struct MCPServersView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(MCPServerStore.self) private var mcp
    @Environment(SecretStore.self) private var secrets
    @State private var isAdding = false
    /// The server just added, to finish setting up once its sheet closes.
    @State private var added: MCPServer?
    @State private var inspected: MCPServer?
    @State private var headerSecrets: MCPServer?
    @State private var removal: MCPServer?
    @State private var credentialRemoval: MCPServer?

    var body: some View {
        @Bindable var mcp = mcp

        ScrollViewReader { proxy in
            Form {
                Section {
                    if mcp.servers.isEmpty {
                        Text(mcp.hasLoaded ? "No MCP servers." : "Loading…")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(mcp.servers) { server in
                        MCPServerRow(server: server) { action in
                            switch action {
                            case .authorise: mcp.authorise(server)
                            case .setHeaderSecrets: headerSecrets = server
                            case .inspect: inspected = server
                            case .removeCredentials: credentialRemoval = server
                            case .remove: removal = server
                            }
                        }
                        .id(server.name)
                    }
                } header: {
                    Text("Servers")
                } footer: {
                    footer
                }
            }
            .formStyle(.grouped)
            .onChange(of: store.mcpServerToReveal, initial: true) { _, name in
                guard let name else { return }
                store.mcpServerToReveal = nil
                withAnimation { proxy.scrollTo(name) }
            }
        }
        .navigationTitle("MCP Servers")
        .task {
            await mcp.refresh()
            await secrets.refresh()
        }
        .toolbar {
            ToolbarItem {
                Button("Add Server", systemImage: "plus") {
                    isAdding = true
                }
                .help("Register an MCP server with sbx")
            }
        }
        .sheet(isPresented: $isAdding, onDismiss: finishAdding) {
            AddMCPServerSheet(added: $added)
        }
        .sheet(item: $inspected) { server in
            MCPServerInspector(server: server)
        }
        .sheet(item: $headerSecrets) { server in
            MCPHeaderSecretsSheet(server: server)
        }
        .sheet(item: $mcp.authorisation) { run in
            SbxCommandSheet(run: run)
        }
        .confirmationDialog(
            "Remove “\(removal?.name ?? "")”?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            presenting: removal
        ) { server in
            Button("Remove", role: .destructive) {
                Task { await mcp.remove(server, removingSecrets: false) }
            }
            if !secrets.mcpSecretNames(forServer: server.name).isEmpty {
                Button("Remove Server and Secrets", role: .destructive) {
                    Task { await mcp.remove(server, removingSecrets: true) }
                }
            }
        } message: { server in
            Text(removalMessage(for: server))
        }
        .confirmationDialog(
            "Remove the Credentials for “\(credentialRemoval?.name ?? "")”?",
            isPresented: Binding(get: { credentialRemoval != nil }, set: { if !$0 { credentialRemoval = nil } }),
            presenting: credentialRemoval
        ) { server in
            Button("Remove Credentials", role: .destructive) {
                Task { await mcp.removeCredentials(server) }
            }
        } message: { _ in
            Text("The server stays registered. You'll need to authorise it again before sandboxes can use it.")
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let error = mcp.loadError {
            Text("Couldn't list MCP servers: \(error)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sandboxes reach these servers through sbx's MCP gateway. Pick servers when you create a sandbox, or load one into a running sandbox. Servers that run on this Mac run outside the sandbox, with your permissions.")
                if let gateway = mcp.servers.lazy.compactMap(\.gateway).first {
                    Text(gateway.signedInAs.map { "Gateway: \(gateway.summary), signed in as \($0)" } ?? "Gateway: \(gateway.summary)")
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Authorises the new server or asks for its header secrets straight
    /// away, as `sbx mcp add` would, once the Add sheet has gone.
    private func finishAdding() {
        guard let server = added else { return }
        added = nil
        switch server.status {
        case .needsAuthorisation: mcp.authorise(server)
        case .needsSecret: headerSecrets = server
        case .ready, .other: break
        }
    }

    private func removalMessage(for server: MCPServer) -> String {
        var message = "Its OAuth credentials are removed too. Sandboxes that have already loaded it keep it until it's unloaded."
        if !secrets.mcpSecretNames(forServer: server.name).isEmpty {
            message += " sbx keeps its header secrets unless you remove them as well, and would use them again for a server added with the same name."
        }
        return message
    }
}

/// A registered server, with its status, a button for the next step when it
/// needs one, and a menu of everything else.
private struct MCPServerRow: View {
    enum Action {
        case authorise
        case setHeaderSecrets
        case inspect
        case removeCredentials
        case remove
    }

    let server: MCPServer
    let perform: (Action) -> Void
    @Environment(MCPServerStore.self) private var mcp

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: server.transport == .remote ? "globe" : "desktopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            HStack(spacing: 6) {
                StatusDot(color: statusColor)
                Text(server.statusTitle)
                    .foregroundStyle(.secondary)
            }
            .help(server.nextStep.map { "sbx suggests: \($0)" } ?? server.statusTitle)
            if mcp.isBusy(server) {
                ProgressView()
                    .controlSize(.small)
            } else {
                switch server.status {
                case .needsAuthorisation:
                    Button("Authorise…") { perform(.authorise) }
                case .needsSecret:
                    Button("Set Secrets…") { perform(.setHeaderSecrets) }
                case .ready, .other:
                    EmptyView()
                }
                Menu {
                    MCPServerActions(server: server, perform: perform)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions for “\(server.name)”")
            }
        }
        .contextMenu {
            MCPServerActions(server: server, perform: perform)
        }
    }

    /// Such as "Remote · 1 header secret not set".
    private var subtitle: String {
        ([server.transportTitle] + [server.detail].compactMap { $0 }).joined(separator: " · ")
    }

    private var statusColor: Color {
        switch server.status {
        case .ready: .green
        case .needsAuthorisation, .needsSecret: .orange
        case .other: .secondary
        }
    }
}

/// The items in a server row's menu and context menu.
private struct MCPServerActions: View {
    let server: MCPServer
    let perform: (MCPServerRow.Action) -> Void
    @Environment(SandboxStore.self) private var store
    @Environment(MCPServerStore.self) private var mcp
    @Environment(SbxStatus.self) private var sbxStatus

    var body: some View {
        Button("Inspect…") { perform(.inspect) }
        if server.transport == .remote {
            Button("Authorise…") { perform(.authorise) }
            Button("Set Header Secrets…") { perform(.setHeaderSecrets) }
        }
        Divider()
        let running = store.sandboxes.filter { $0.state == .running }
        Menu("Load Into") {
            if running.isEmpty {
                Button("No Running Sandboxes") {}
                    .disabled(true)
            }
            ForEach(running) { sandbox in
                Button(sandbox.name) {
                    Task { await mcp.load(server, into: sandbox) }
                }
            }
        }
        if server.canUnload && sbxStatus.supportsMCPUnload {
            Menu("Unload From") {
                if running.isEmpty {
                    Button("No Running Sandboxes") {}
                        .disabled(true)
                }
                ForEach(running) { sandbox in
                    Button(sandbox.name) {
                        mcp.unloadCandidate = MCPServerStore.Unload(server: server, sandbox: sandbox)
                    }
                }
            }
        }
        Divider()
        if server.transport == .remote {
            Button("Remove Credentials…") { perform(.removeCredentials) }
        }
        Button("Remove…", role: .destructive) { perform(.remove) }
    }
}

/// What `sbx mcp inspect` reports about a server.
private struct MCPServerInspector: View {
    let server: MCPServer
    @Environment(\.dismiss) private var dismiss
    @State private var details: MCPServerDetails?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Transport", value: server.transportLabel ?? server.transportTitle)
                    LabeledContent("Status", value: server.statusTitle)
                    if let detail = server.detail {
                        LabeledContent("Detail", value: detail)
                    }
                    if let nextStep = server.nextStep {
                        LabeledContent("Next Step") {
                            Text(nextStep)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    if let gateway = server.gateway {
                        LabeledContent("Gateway", value: gateway.summary)
                    }
                }
                if let details {
                    detailSections(details)
                } else {
                    Section {
                        Text(error.map { "Couldn't inspect the server: \($0)" } ?? "Loading…")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            // Sheets separate their buttons from the content with a line.
            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 400, idealHeight: 480)
        .navigationTitle(server.name)
        .task {
            do {
                details = try await MCPServerDetails.fetch(for: server)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func detailSections(_ details: MCPServerDetails) -> some View {
        Section {
            if let url = details.url {
                LabeledContent("URL") {
                    Text(url).textSelection(.enabled)
                }
            }
            if let transport = details.remoteTransport {
                LabeledContent("Protocol", value: transport)
            }
            if !details.command.isEmpty {
                LabeledContent("Command") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(details.command.joined(separator: " "))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        if let resolved = details.resolvedCommand {
                            Text(resolved)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if server.transport == .remote {
                LabeledContent("OAuth") {
                    Text(oauthText(details))
                        .textSelection(.enabled)
                }
            }
            ForEach(details.otherFields.sorted { $0.key < $1.key }, id: \.key) { field in
                LabeledContent(field.key) {
                    Text(field.value).textSelection(.enabled)
                }
            }
        } footer: {
            if server.transport == .local {
                Text("Runs on your Mac with your permissions, outside the sandbox.")
                    .foregroundStyle(.secondary)
            }
        }
        if !details.headers.isEmpty {
            Section("Headers") {
                ForEach(details.headers, id: \.name) { header in
                    LabeledContent(header.name) {
                        Text(header.value)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        if !details.headerSecrets.isEmpty {
            Section {
                ForEach(details.headerSecrets) { secret in
                    LabeledContent {
                        Text(secret.isStored ? "Stored" : "Not set")
                    } label: {
                        Text(secret.placeholder)
                            .font(.callout.monospaced())
                    }
                }
            } header: {
                Text("Header Secrets")
            } footer: {
                Text("The values for the headers' placeholders, kept in sbx's secret store as mcp:\(details.name):<placeholder> and never shown. Change them with Set Header Secrets in the server's menu.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func oauthText(_ details: MCPServerDetails) -> String {
        guard details.requiresOAuth else { return "Not required" }
        let hosts = details.oauthIssuers.map { URL(string: $0)?.host() ?? $0 }
        return hosts.isEmpty ? "Required" : "Required, from \(hosts.joined(separator: ", "))"
    }
}

/// Values for the `${placeholder}`s in a server's headers, stored in sbx's
/// secret store as `mcp:<server>:<placeholder>`.
private struct MCPHeaderSecretsSheet: View {
    let server: MCPServer
    @Environment(MCPServerStore.self) private var mcp
    @Environment(\.dismiss) private var dismiss
    @State private var details: MCPServerDetails?
    @State private var values: [String: String] = [:]
    @State private var loadError: String?
    @State private var error: String?
    @State private var isSaving = false
    @State private var removal: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if let details {
                        if details.headerSecrets.isEmpty {
                            Text("This server's headers have no placeholders.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(details.headerSecrets) { secret in
                            HStack {
                                SecureField(
                                    "${\(secret.placeholder)}",
                                    text: binding(for: secret.placeholder),
                                    prompt: Text(secret.isStored ? "Stored" : "Value")
                                )
                                if secret.isStored {
                                    RemoveButton(help: "Remove the stored value") {
                                        removal = secret.placeholder
                                    }
                                }
                            }
                        }
                    } else {
                        Text(loadError.map { "Couldn't inspect the server: \($0)" } ?? "Loading…")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if let error {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else {
                        Text("Passed to sbx on standard input and kept in its secret store as mcp:\(server.name):<placeholder>. Restart sandboxes that use this server to pick up a change.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)

            // Sheets separate their buttons from the content with a line.
            Divider()

            HStack {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(isSaving || filledValues.isEmpty)
            }
            .padding(20)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 280, idealHeight: 320)
        .navigationTitle("Header Secrets for “\(server.name)”")
        .task { await loadDetails() }
        .confirmationDialog(
            "Remove the Value for ${\(removal ?? "")}?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            presenting: removal
        ) { placeholder in
            Button("Remove", role: .destructive) {
                Task { await remove(placeholder) }
            }
        } message: { _ in
            Text("“\(server.name)” can't connect until it has a value again.")
        }
    }

    private var filledValues: [String: String] {
        values.compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func binding(for placeholder: String) -> Binding<String> {
        Binding(get: { values[placeholder] ?? "" }, set: { values[placeholder] = $0 })
    }

    private func loadDetails() async {
        do {
            details = try await MCPServerDetails.fetch(for: server)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            try await mcp.setHeaderSecrets(for: server.name, values: filledValues)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }

    private func remove(_ placeholder: String) async {
        isSaving = true
        error = nil
        do {
            try await mcp.removeHeaderSecret(for: server.name, placeholder: placeholder)
            await loadDetails()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}

/// Registers a server with `sbx mcp add`.
private struct AddMCPServerSheet: View {
    /// Set to the new server as sbx lists it.
    @Binding var added: MCPServer?
    @Environment(MCPServerStore.self) private var mcp
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MCPServerDraft()
    @State private var isSaving = false
    @State private var error: String?
    @State private var confirmsCommand = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("notion"))
                    Picker("Source", selection: $draft.source) {
                        ForEach(MCPServerDraft.Source.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch draft.source {
                case .url:
                    urlSections
                case .command:
                    commandSection
                }

                Section {
                    Text(draft.commandLine)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("Command")
                } footer: {
                    if let error {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)

            // Sheets separate their buttons from the content with a line.
            Divider()

            HStack {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if draft.source == .command {
                        confirmsCommand = true
                    } else {
                        Task { await add() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(isSaving || missing != nil)
                .help(missing ?? "")
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 620)
        .navigationTitle("Add MCP Server")
        .confirmationDialog(
            "Add a Server That Runs on Your Mac?",
            isPresented: $confirmsCommand
        ) {
            Button("Add Server") {
                Task { await add() }
            }
        } message: {
            Text("“\(draft.command.trimmingCharacters(in: .whitespaces))” runs on your Mac with your permissions, outside the sandbox, whenever a sandbox uses the server. Only add commands you trust.")
        }
    }

    @ViewBuilder
    private var urlSections: some View {
        Section {
            TextField("URL", text: $draft.url, prompt: Text("https://mcp.example.com/mcp"))
            Toggle("Run on this Mac", isOn: $draft.runsLocally)
        } footer: {
            Text("A remote MCP endpoint, a registry or server.json manifest URL, or a dhi.io image. sbx works out which. Run on this Mac starts a registry or manifest server with Docker on your Mac instead.")
                .foregroundStyle(.secondary)
        }

        Section {
            ForEach($draft.headers) { $header in
                HStack {
                    TextField("Name", text: $header.name, prompt: Text("Authorization"))
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    TextField("Value", text: $header.value, prompt: Text("Bearer ${api-key}"))
                        .labelsHidden()
                    RemoveButton(help: "Remove header") {
                        draft.headers.removeAll { $0.id == header.id }
                    }
                }
                .font(.body.monospaced())
            }
            Button("Add Header", systemImage: "plus") {
                draft.headers.append(MCPServerDraft.Header())
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Headers")
        } footer: {
            Text("Sent with every request to a remote endpoint. Write a secret as a ${placeholder}, such as Bearer ${api-key}, and enter its value below.")
                .foregroundStyle(.secondary)
        }

        if !draft.placeholders.isEmpty {
            let stored = mcp.storedPlaceholders(forServer: draft.trimmedName)
            Section {
                ForEach(draft.placeholders, id: \.self) { placeholder in
                    SecureField(
                        "${\(placeholder)}",
                        text: secretBinding(for: placeholder),
                        prompt: Text(stored.contains(placeholder) ? "Stored" : "Value")
                    )
                }
            } header: {
                Text("Header Secrets")
            } footer: {
                Text("sbx needs these before it adds the server. They're passed to sbx on standard input and kept in its secret store as mcp:\(draft.trimmedName.isEmpty ? "<name>" : draft.trimmedName):<placeholder>, never in the server's settings.")
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            TextField("Client ID", text: $draft.clientID, prompt: Text("Optional"))
            TextField("Scopes", text: $draft.scopes, prompt: Text("Optional, such as read write"))
            Toggle("Allow private network addresses", isOn: $draft.skipsSSRFCheck)
        } header: {
            Text("OAuth")
        } footer: {
            Text("A client ID is only needed for servers that don't register clients themselves. Allowing private addresses turns off sbx's warnings for URLs that resolve to your network; only use it for servers you control.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var commandSection: some View {
        Section {
            TextField("Command", text: $draft.command, prompt: Text("npx"))
                .font(.body.monospaced())
            LabeledContent("Folder") {
                HStack {
                    if let directory = draft.directory {
                        Label((directory.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(directory.path)
                        RemoveButton(help: "Use the default folder") {
                            draft.directory = nil
                        }
                    } else {
                        Text("Default")
                            .foregroundStyle(.secondary)
                    }
                    Button("Choose…") {
                        draft.directory = OpenPanel.choose(directories: true, prompt: "Choose", message: "Choose the folder the server runs in.").first
                    }
                }
            }
        } footer: {
            Text("Runs on your Mac with your permissions, outside the sandbox. Only add commands you trust.")
                .foregroundStyle(.secondary)
        }

        Section("Arguments") {
            ForEach($draft.arguments) { $argument in
                HStack {
                    TextField("Argument", text: $argument.value, prompt: Text("Argument"))
                        .labelsHidden()
                    RemoveButton(help: "Remove argument") {
                        draft.arguments.removeAll { $0.id == argument.id }
                    }
                }
                .font(.body.monospaced())
            }
            Button("Add Argument", systemImage: "plus") {
                draft.arguments.append(MCPServerDraft.Argument())
            }
            .buttonStyle(.borderless)
        }
    }

    /// What's missing before it can be added, including header secrets.
    private var missing: String? {
        draft.missing ?? draft.missingSecret(stored: mcp.storedPlaceholders(forServer: draft.trimmedName))
    }

    private func secretBinding(for placeholder: String) -> Binding<String> {
        Binding(
            get: { draft.headerSecretValues[placeholder] ?? "" },
            set: { draft.headerSecretValues[placeholder] = $0 }
        )
    }

    private func add() async {
        isSaving = true
        error = nil
        do {
            added = try await mcp.add(draft)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}
