import SwiftUI

/// Management › Secrets: the secrets sbx gives sandboxes, globally and for
/// each sandbox, with ways to add, edit and remove them.
struct SecretsView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(SecretStore.self) private var secrets
    @State private var editor: SecretDraft?
    @State private var removal: SecretRemoval?

    var body: some View {
        Form {
            Section {
                if secrets.globalSecrets.isEmpty {
                    Text(secrets.hasLoaded ? "No global secrets." : "Loading…")
                        .foregroundStyle(.secondary)
                }
                ForEach(secrets.globalSecrets) { secret in
                    SecretRow(secret: secret, editor: $editor, removal: $removal)
                }
            } header: {
                Text("Global")
            } footer: {
                if let error = secrets.loadError {
                    Text("Couldn't list secrets: \(error)")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Service secrets apply to every sandbox straight away, including existing ones. Registry credentials only go to sandboxes created after they're set, and existing sandboxes may need recreating to get a custom secret's environment variable.")
                        .foregroundStyle(.secondary)
                }
            }

            if !secrets.mcpSecrets.isEmpty {
                Section {
                    ForEach(secrets.mcpSecrets) { secret in
                        SecretRow(secret: secret, editor: $editor, removal: $removal)
                    }
                } header: {
                    Text("MCP Servers")
                } footer: {
                    Text("Header values and OAuth client secrets for MCP servers. Set and remove them in Management › MCP Servers. Running sandboxes pick up a change when they restart.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(secrets.sandboxSecrets) { group in
                let sandbox = store.sandboxes.first { $0.name == group.sandbox }
                Section {
                    ForEach(group.secrets) { secret in
                        SecretRow(secret: secret, editor: $editor, removal: $removal)
                    }
                } header: {
                    HStack(spacing: 5) {
                        AgentIcon(agent: sandbox?.knownAgent, size: 12)
                            .foregroundStyle(sandbox?.knownAgent?.color ?? .secondary)
                        Text(group.sandbox)
                    }
                } footer: {
                    // sbx keeps a sandbox's secrets when it's removed some
                    // other way, such as from the command line.
                    if store.hasLoaded && sandbox == nil {
                        HStack {
                            Text("This sandbox no longer exists.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove Secrets…") {
                                removal = SecretRemoval(secrets: group.secrets, sandbox: group.sandbox)
                            }
                            .disabled(group.secrets.allSatisfy { $0.removeArguments == nil || secrets.isRemoving($0) })
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Secrets")
        .task {
            await secrets.refresh()
        }
        .toolbar {
            ToolbarItem {
                Button("Add Secret", systemImage: "plus") {
                    editor = SecretDraft()
                }
                .help("Store a secret for a service, a custom host or a registry")
            }
        }
        .secretEditing(editor: $editor, removal: $removal)
    }
}

/// Secrets to remove once the user confirms.
struct SecretRemoval: Identifiable {
    let id = UUID()
    let secrets: [SbxSecret]
    /// Set when removing every secret of a sandbox that no longer exists.
    var sandbox: String?

    var title: String {
        if let sandbox {
            return "Remove the secrets for “\(sandbox)”?"
        }
        return "Remove the \(secrets.first?.title ?? "") secret?"
    }

    var message: String {
        if sandbox != nil {
            return "The sandbox no longer exists, so nothing uses them."
        }
        switch (secrets.first?.kind, secrets.first?.scope) {
        case let (_, .sandbox(name)): return "“\(name)” will no longer get it."
        case (_, .host): return "sbx will no longer use it to pull templates and kits."
        case (.registry, _): return "Sandboxes created from now on won't get it."
        case (.service, _): return "Sandboxes stop getting it straight away, unless they have their own."
        default: return "Sandboxes will no longer get it."
        }
    }
}

extension View {
    /// The sheet for adding or editing a secret, and the confirmation for
    /// removing secrets. Failures to remove show through the secret store's
    /// `actionError`, in the main window.
    func secretEditing(editor: Binding<SecretDraft?>, removal: Binding<SecretRemoval?>) -> some View {
        modifier(SecretEditing(editor: editor, removal: removal))
    }
}

private struct SecretEditing: ViewModifier {
    @Binding var editor: SecretDraft?
    @Binding var removal: SecretRemoval?
    @Environment(SandboxStore.self) private var store
    @Environment(SecretStore.self) private var secrets

    func body(content: Content) -> some View {
        content
            .sheet(item: $editor) { draft in
                SecretEditor(draft: draft, sandboxNames: store.sandboxes.map(\.name))
            }
            .confirmationDialog(
                removal?.title ?? "",
                isPresented: Binding(
                    get: { removal != nil },
                    set: { if !$0 { removal = nil } }
                ),
                presenting: removal
            ) { removal in
                Button("Remove", role: .destructive) {
                    Task { await secrets.remove(removal.secrets) }
                }
            } message: { removal in
                Text(removal.message)
            }
    }
}

/// A secret with buttons to edit and remove it, or a label saying where it's
/// managed when it's read-only.
struct SecretRow: View {
    let secret: SbxSecret
    @Binding var editor: SecretDraft?
    @Binding var removal: SecretRemoval?
    /// Shown in place of the buttons, such as "Global" for a global secret
    /// listed on a sandbox's page.
    var readOnlyLabel: String?
    /// Whether a secret scoped to the sandbox replaces this one.
    var isOverridden = false
    @Environment(SandboxStore.self) private var store
    @Environment(SecretStore.self) private var secrets

    var body: some View {
        HStack(spacing: 10) {
            SecretIcon(secret: secret)
            VStack(alignment: .leading, spacing: 2) {
                Text(secret.title)
                ForEach(details, id: \.self) { detail in
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if let readOnlyLabel {
                Text(isOverridden ? "\(readOnlyLabel) · Overridden" : readOnlyLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
                    .help(readOnlyHelp)
            } else if secrets.isRemoving(secret) {
                ProgressView()
                    .controlSize(.small)
            } else if let mcp = secret.mcpName {
                Button("Show Server") {
                    store.mcpServerToReveal = mcp.server
                    store.selection = .mcpServers
                }
                .help("Change or remove it in Management › MCP Servers")
            } else {
                if secret.canEdit {
                    Button("Edit…") { edit() }
                        .help("Change where this secret's value comes from")
                }
                if secret.removeArguments != nil {
                    Button("Remove…", role: .destructive) { remove() }
                }
            }
        }
        .opacity(isOverridden ? 0.6 : 1)
        .contextMenu {
            if readOnlyLabel == nil, secret.canEdit {
                Button("Edit…") { edit() }
            }
            if readOnlyLabel == nil, secret.removeArguments != nil {
                Button("Remove…", role: .destructive) { remove() }
            }
        }
    }

    private var readOnlyHelp: String {
        if isOverridden {
            return "A secret for this sandbox is used instead of this global one."
        }
        return switch secret.kind {
        case .registry: "A global secret, given only to sandboxes created after it was set. Change it in Management › Secrets."
        case .custom: "A global secret. Sandboxes created before it was set may not have its environment variable. Change it in Management › Secrets."
        case .service, .other: "A global secret. Change it in Management › Secrets."
        }
    }

    private func edit() {
        editor = SecretDraft(editing: secret)
    }

    private func remove() {
        removal = SecretRemoval(secrets: [secret])
    }

    /// What it's for and where its value comes from, one line each.
    private var details: [String] {
        var lines: [String] = []
        if let mcp = secret.mcpName {
            lines.append(mcp.key == "client_secret" ? "OAuth client secret for “\(mcp.server)”" : "Header value for “\(mcp.server)”")
        }
        switch secret.kind {
        case .service, .other:
            break
        case .custom:
            var line = secret.hosts.joined(separator: ", ")
            if let variable = secret.environmentVariable {
                line += line.isEmpty ? "$\(variable)" : " · $\(variable)"
            }
            if !line.isEmpty {
                lines.append(line)
            }
        case .registry:
            var line = secret.scope == .host ? "Pulls on this Mac only" : "Registry credentials"
            if let username = secret.username {
                line += " · \(username)"
            }
            lines.append(line)
        }
        var source: String
        switch secret.source {
        case .value:
            source = secret.maskedValue ?? "Stored value"
        case let .ref(ref):
            source = ref.lowercased().hasPrefix("arn:") ? "AWS Secrets Manager: \(ref)" : "1Password: \(ref)"
        case let .command(command):
            source = command.isEmpty ? "Command" : "Command: \(command)"
        case .oauth:
            source = "Signed in with OAuth"
        }
        if let refresh = secret.refresh, secret.source != .value {
            source += " · refresh \(refresh)"
        }
        lines.append(source)
        return lines
    }
}

/// The service's logo when there is one, otherwise a symbol for the kind of
/// secret.
struct SecretIcon: View {
    let secret: SbxSecret
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size + 2, height: size)
    }

    private var assetName: String? {
        guard secret.kind == .service else { return nil }
        return switch secret.name.lowercased() {
        case "anthropic": "ServiceAnthropic"
        case "copilot": "AgentCopilot"
        case "cursor": "AgentCursor"
        case "github": "ServiceGitHub"
        case "google": "ServiceGoogle"
        case "mistral": "ServiceMistral"
        case "openai": "AgentCodex"
        case "openrouter": "ServiceOpenRouter"
        default: nil
        }
    }

    private var symbol: String {
        if secret.kind == .mcp {
            return "puzzlepiece.extension"
        }
        return switch secret.kind {
        case .service, .other: "key"
        case .custom: "key.horizontal"
        case .registry: "shippingbox"
        }
    }
}

private struct SecretEditor: View {
    @State var draft: SecretDraft
    let sandboxNames: [String]
    @Environment(SecretStore.self) private var secrets
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if !draft.isEditing {
                    Picker("Type", selection: $draft.kind) {
                        ForEach(SecretDraft.Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draft.kind) { _, kind in
                        // Only registry credentials can be for the host alone.
                        if kind != .registry && draft.scope == .host {
                            draft.scope = .global
                        }
                    }
                }

                Section {
                    switch draft.kind {
                    case .service:
                        Picker("Service", selection: $draft.service) {
                            ForEach(services, id: \.self) { service in
                                Text(SbxSecret.serviceTitle(service)).tag(service)
                            }
                        }
                        .disabled(draft.isEditing)
                    case .custom:
                        TextField("Hosts", text: $draft.hosts, prompt: Text("api.example.com, *.example.com"))
                        TextField("Environment variable", text: $draft.environmentVariable, prompt: Text("API_KEY"))
                        TextField("Placeholder", text: $draft.placeholder, prompt: Text("Generated, or such as sk-{rand}"))
                            .disabled(draft.isEditing && draft.original?.placeholder != nil)
                    case .registry:
                        TextField("Registry", text: $draft.registry, prompt: Text("ghcr.io"))
                            .disabled(draft.isEditing)
                        TextField("Username", text: $draft.username, prompt: Text("Optional"))
                        TextField("Auth endpoint", text: $draft.authEndpoint, prompt: Text("Optional, such as https://gitlab.example.com/jwt/auth"))
                    }
                    Picker("For", selection: $draft.scope) {
                        if draft.kind == .registry {
                            Text("Pulls on this Mac only").tag(SbxSecret.Scope.host)
                        }
                        Text(draft.kind == .registry ? "All new sandboxes" : "All sandboxes").tag(SbxSecret.Scope.global)
                        if !scopeNames.isEmpty {
                            Divider()
                        }
                        ForEach(scopeNames, id: \.self) { name in
                            Text(name).tag(SbxSecret.Scope.sandbox(name))
                        }
                    }
                    .disabled(draft.isEditing)
                } footer: {
                    Text(scopeFooter)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if draft.kind != .registry {
                        Picker("Source", selection: $draft.sourceKind) {
                            ForEach(SecretDraft.SourceKind.allCases) { source in
                                Text(source.title).tag(source)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    switch draft.effectiveSourceKind {
                    case .value:
                        SecureField(draft.kind == .registry ? "Password" : "Value", text: $draft.value, prompt: Text(valuePrompt))
                    case .ref:
                        TextField("Reference", text: $draft.ref, prompt: Text("op://Vault/Item/field or arn:aws:secretsmanager:…"))
                    case .command:
                        TextField("Command", text: $draft.command, prompt: Text("gh auth token"))
                            .fontDesign(.monospaced)
                    }
                    if draft.effectiveSourceKind != .value {
                        TextField("Refresh", text: $draft.refresh, prompt: Text("Default, or such as 30m or on-demand"))
                    }
                } footer: {
                    if let error {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else {
                        Text(sourceFooter)
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
                Button(draft.isEditing ? "Save" : "Add") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(isSaving || draft.missing != nil)
                .help(draft.missing ?? "")
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 440, idealHeight: 500)
        .navigationTitle(draft.isEditing ? "Edit Secret" : "Add Secret")
    }

    /// The services to choose from, keeping one sbx listed that this app
    /// doesn't know about yet.
    private var services: [String] {
        SbxSecret.services.contains(draft.service) ? SbxSecret.services : [draft.service] + SbxSecret.services
    }

    /// The sandboxes to choose from, keeping the one being edited even if
    /// it's no longer listed.
    private var scopeNames: [String] {
        guard let sandbox = draft.scope.sandboxName, !sandboxNames.contains(sandbox) else { return sandboxNames }
        return [sandbox] + sandboxNames
    }

    /// Says what goes in the field, or that there's already a stored value.
    private var valuePrompt: String {
        if draft.original?.source == .value {
            return "Stored"
        }
        return switch draft.kind {
        case .service: "API key or token"
        case .custom: "Value"
        case .registry: "Password or access token"
        }
    }

    private var scopeFooter: String {
        switch (draft.kind, draft.scope) {
        case (.custom, .sandbox):
            "Sandboxes see the placeholder instead of the secret. sbx swaps in the secret on requests to these hosts."
        case (.custom, _):
            "Sandboxes see the placeholder instead of the secret. sbx swaps in the secret on requests to these hosts. Existing sandboxes may need recreating to get the environment variable."
        case (.registry, .host):
            "Used to pull private templates and kits. Sandboxes don't get it."
        case (.registry, .global):
            "Given to sandboxes created after it's set. To use it in an existing sandbox, add it for that sandbox."
        case (_, .sandbox):
            "Used instead of the global secret for this sandbox."
        default:
            "Applies to every sandbox straight away, including existing ones."
        }
    }

    private var sourceFooter: String {
        switch draft.effectiveSourceKind {
        case .value:
            draft.kind == .custom
                ? "sbx only accepts a custom secret's value as an argument, so it's briefly visible to other processes on this Mac."
                : "Passed to sbx on standard input, so it isn't visible to other processes."
        case .ref:
            "sbx reads the secret with the 1Password (op) or AWS CLI when it's needed, so it must be installed and signed in."
        case .command:
            "sbx runs this on your Mac and uses what it prints. Use an absolute path for scripts outside your workspaces."
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            try await secrets.save(draft)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}
