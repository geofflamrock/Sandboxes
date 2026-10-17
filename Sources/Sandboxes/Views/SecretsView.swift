import SwiftUI

/// Management › Secrets: the secrets sbx gives sandboxes, globally and for
/// each sandbox, with ways to add, replace and remove them.
struct SecretsView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(SecretStore.self) private var secrets
    @State private var editor: SecretDraft?
    @State private var removalCandidate: SbxSecret?
    @State private var removalError: String?

    var body: some View {
        Form {
            Section {
                if secrets.globalSecrets.isEmpty {
                    placeholder("No global secrets.")
                }
                ForEach(secrets.globalSecrets) { secret in
                    row(for: secret)
                }
            } header: {
                Text("Global")
            } footer: {
                if let error = secrets.loadError {
                    Text("Couldn't list secrets: \(error)")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Given to sandboxes created after the secret is set. To give one to an existing sandbox, add it to that sandbox.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(secrets.sandboxSecrets) { group in
                Section {
                    ForEach(group.secrets) { secret in
                        row(for: secret)
                    }
                } header: {
                    sandboxHeader(group.sandbox)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Secrets")
        .task {
            await secrets.refresh()
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
                Button("Add Secret", systemImage: "plus") {
                    editor = SecretDraft()
                }
                .help("Store an API key or token for a service")
            }
        }
        .sheet(item: $editor) { draft in
            SecretEditor(draft: draft, sandboxNames: store.sandboxes.map(\.name))
        }
        .confirmationDialog(
            "Remove the \(removalCandidate?.title ?? "") secret?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            presenting: removalCandidate
        ) { secret in
            Button("Remove", role: .destructive) {
                Task {
                    do {
                        try await secrets.remove(secret)
                    } catch {
                        removalError = error.localizedDescription
                    }
                }
            }
        } message: { secret in
            Text(removalMessage(for: secret))
        }
        .alert(
            "Couldn't Remove the Secret",
            isPresented: Binding(
                get: { removalError != nil },
                set: { if !$0 { removalError = nil } }
            ),
            presenting: removalError
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error)
        }
    }

    private func row(for secret: SbxSecret) -> some View {
        HStack(spacing: 10) {
            Image(systemName: secret.kind == .registry ? "server.rack" : "key")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(secret.title)
                Text(detail(for: secret))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if secrets.isRemoving(secret) {
                ProgressView()
                    .controlSize(.small)
            } else {
                if secret.kind == .service {
                    Button("Replace…") {
                        editor = SecretDraft(replacing: secret)
                    }
                    .help("Store a new value for this secret")
                }
                Button("Remove…", role: .destructive) {
                    removalCandidate = secret
                }
            }
        }
        .contextMenu {
            if secret.kind == .service {
                Button("Replace…") { editor = SecretDraft(replacing: secret) }
            }
            Button("Remove…", role: .destructive) { removalCandidate = secret }
        }
    }

    private func detail(for secret: SbxSecret) -> String {
        var parts: [String] = []
        switch secret.kind {
        case .service:
            if secret.title != secret.name {
                parts.append(secret.name)
            }
        case .registry:
            parts.append(secret.scope == .host ? "Registry credentials for the host only" : "Registry credentials")
        }
        if let source = secret.source, !source.isEmpty {
            parts.append(source)
        }
        return parts.isEmpty ? "Stored" : parts.joined(separator: " · ")
    }

    private func removalMessage(for secret: SbxSecret) -> String {
        switch secret.scope {
        case .global, .host:
            "Sandboxes created from now on won't get it."
        case let .sandbox(name):
            "“\(name)” will no longer get it."
        }
    }

    private func sandboxHeader(_ name: String) -> some View {
        let sandbox = store.sandboxes.first { $0.name == name }
        return HStack(spacing: 5) {
            AgentIcon(agent: sandbox?.knownAgent, size: 12)
                .foregroundStyle(sandbox?.knownAgent?.color ?? .secondary)
            Text(name)
        }
    }

    /// A row for an empty section. A section with no rows draws its header
    /// in a smaller style.
    private func placeholder(_ text: String) -> some View {
        Text(secrets.hasLoaded ? text : "Loading…")
            .foregroundStyle(.secondary)
    }
}

/// A secret being added, or a new value for one.
struct SecretDraft: Identifiable {
    let id = UUID()
    var service = "github"
    /// The sandbox it's for, or nil for every sandbox created from now on.
    var sandbox: String?
    var value = ""
    /// Whether this replaces an existing secret, so the service and scope
    /// are fixed.
    var isReplacing = false

    init() {}

    init(replacing secret: SbxSecret) {
        service = secret.name
        sandbox = secret.scope.sandboxName
        isReplacing = true
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
                Section {
                    Picker("Service", selection: $draft.service) {
                        ForEach(services, id: \.self) { service in
                            Text(SbxSecret.serviceTitle(service)).tag(service)
                        }
                    }
                    .disabled(draft.isReplacing)
                    Picker("For", selection: $draft.sandbox) {
                        Text("All new sandboxes").tag(String?.none)
                        if !scopeNames.isEmpty {
                            Divider()
                        }
                        ForEach(scopeNames, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    .disabled(draft.isReplacing)
                    SecureField("Token", text: $draft.value, prompt: Text("Paste the API key or token"))
                } footer: {
                    if let error {
                        Text(error)
                            .foregroundStyle(.red)
                    } else if draft.sandbox == nil {
                        Text("Given to sandboxes created after it's set.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Used instead of the global secret for this sandbox.")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isSaving)
            }
            .formStyle(.grouped)

            HStack {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isReplacing ? "Replace" : "Add") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(isSaving || trimmedValue.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .navigationTitle(draft.isReplacing ? "Replace \(SbxSecret.serviceTitle(draft.service)) Secret" : "Add Secret")
    }

    /// The services to choose from, keeping one sbx listed that this app
    /// doesn't know about yet.
    private var services: [String] {
        SbxSecret.services.contains(draft.service) ? SbxSecret.services : [draft.service] + SbxSecret.services
    }

    /// The sandboxes to choose from, keeping the one being replaced even if
    /// it's no longer listed.
    private var scopeNames: [String] {
        guard let sandbox = draft.sandbox, !sandboxNames.contains(sandbox) else { return sandboxNames }
        return [sandbox] + sandboxNames
    }

    private var trimmedValue: String {
        draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            try await secrets.set(service: draft.service, value: trimmedValue, sandbox: draft.sandbox)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}
