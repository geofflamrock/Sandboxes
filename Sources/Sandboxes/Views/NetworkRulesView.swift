import SwiftUI

/// Management › Network Rules: the network rules for every sandbox and for
/// each one, with ways to add, edit and remove those added locally.
struct NetworkRulesView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(NetworkRuleStore.self) private var networkRules
    @State private var editor: NetworkRuleDraft?
    @State private var removal: NetworkRule?

    var body: some View {
        Form {
            Section {
                if networkRules.globalRules.isEmpty {
                    Text(networkRules.hasLoaded ? "No rules for all sandboxes." : "Loading…")
                        .foregroundStyle(.secondary)
                }
                ForEach(networkRules.globalRules) { rule in
                    NetworkRuleRow(rule: rule, editor: $editor, removal: $removal)
                }
            } header: {
                Text("All Sandboxes")
            } footer: {
                if let error = networkRules.loadError {
                    Text("Couldn't list network rules: \(error)")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Deny rules take precedence over allow rules. Changes apply to running sandboxes straight away.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(networkRules.sandboxRules) { group in
                let sandbox = store.sandboxes.first { $0.name == group.sandbox }
                Section {
                    ForEach(group.rules) { rule in
                        NetworkRuleRow(rule: rule, editor: $editor, removal: $removal)
                    }
                } header: {
                    HStack(spacing: 5) {
                        AgentIcon(agent: sandbox?.knownAgent, size: 12)
                            .foregroundStyle(sandbox?.knownAgent?.color ?? .secondary)
                        Text(group.sandbox)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Network Rules")
        .task {
            await networkRules.refresh()
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
                Button("Add Network Rule", systemImage: "plus") {
                    editor = NetworkRuleDraft()
                }
                .help("Allow or deny network access to hosts, for every sandbox or one")
            }
        }
        .networkRuleEditing(editor: $editor, removal: $removal)
    }
}

extension View {
    /// The sheet for adding or editing a network rule, and the confirmation
    /// for removing one. Failures to remove show through the network rule
    /// store's `actionError`, in the main window.
    func networkRuleEditing(editor: Binding<NetworkRuleDraft?>, removal: Binding<NetworkRule?>) -> some View {
        modifier(NetworkRuleEditing(editor: editor, removal: removal))
    }
}

private struct NetworkRuleEditing: ViewModifier {
    @Binding var editor: NetworkRuleDraft?
    @Binding var removal: NetworkRule?
    @Environment(SandboxStore.self) private var store
    @Environment(NetworkRuleStore.self) private var networkRules

    func body(content: Content) -> some View {
        content
            .sheet(item: $editor) { draft in
                NetworkRuleEditor(draft: draft, sandboxNames: store.sandboxes.map(\.name))
            }
            .confirmationDialog(
                "Remove the rule for “\(removal?.resources.joined(separator: ", ") ?? "")”?",
                isPresented: Binding(
                    get: { removal != nil },
                    set: { if !$0 { removal = nil } }
                ),
                presenting: removal
            ) { rule in
                Button("Remove", role: .destructive) {
                    Task { await networkRules.remove(rule) }
                }
            } message: { rule in
                Text(removalMessage(for: rule))
            }
    }

    private func removalMessage(for rule: NetworkRule) -> String {
        let who = rule.sandboxName.map { "“\($0)”" } ?? "Sandboxes"
        return rule.decision == .allow
            ? "\(who) will no longer be allowed to reach these hosts, unless another rule allows them."
            : "\(who) will no longer be blocked from these hosts, unless another rule blocks them."
    }
}

/// A network rule with buttons to edit and remove it, or a label saying
/// where it's managed when it can't be changed here, such as a kit's or an
/// organization's rule.
struct NetworkRuleRow: View {
    let rule: NetworkRule
    @Binding var editor: NetworkRuleDraft?
    @Binding var removal: NetworkRule?
    /// Shown in place of the buttons, such as "Global" for a rule for all
    /// sandboxes listed on a sandbox's page.
    var readOnlyLabel: String?
    @Environment(NetworkRuleStore.self) private var networkRules

    var body: some View {
        HStack(spacing: 10) {
            DecisionLabel(decision: rule.decision, style: .rule)
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.resources.joined(separator: ", "))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let details {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let label = rule.isLocal ? readOnlyLabel : sourceLabel {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
                    .help(readOnlyHelp)
            } else if networkRules.isRemoving(rule) {
                ProgressView()
                    .controlSize(.small)
            } else {
                if rule.canEdit {
                    Button("Edit…") { edit() }
                }
                Button("Remove…", role: .destructive) { remove() }
            }
        }
        .contextMenu {
            if isManagedHere, rule.canEdit {
                Button("Edit…") { edit() }
            }
            if isManagedHere {
                Button("Remove…", role: .destructive) { remove() }
            }
        }
    }

    private var isManagedHere: Bool {
        rule.isLocal && readOnlyLabel == nil
    }

    private func edit() {
        editor = NetworkRuleDraft(editing: rule)
    }

    private func remove() {
        removal = rule
    }

    private var sourceLabel: String {
        switch rule.source?.lowercased() {
        case "org": "Organization"
        case let source?: source.capitalized
        case nil: "Local"
        }
    }

    private var readOnlyHelp: String {
        if rule.isLocal {
            return "A rule for all sandboxes. Change it in Management › Network Rules."
        }
        return "Set by \(rule.source?.lowercased() == "org" ? "your organization" : "a kit"), so it can't be changed here."
    }

    /// The protocols, and any HTTP method and path, such as "TCP · GET /repos/**".
    private var details: String? {
        var parts: [String] = []
        let protocols = NetworkRuleDraft.Protocols(rule.protocols)
        if protocols != .automatic {
            parts.append(protocols.title)
        }
        let request = [rule.method, rule.path].compactMap { $0 }.joined(separator: " ")
        if !request.isEmpty {
            parts.append(request)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct NetworkRuleEditor: View {
    @State var draft: NetworkRuleDraft
    let sandboxNames: [String]
    @Environment(NetworkRuleStore.self) private var networkRules
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Decision", selection: $draft.decision) {
                    Text("Allow").tag(PolicyDecision.allow)
                    Text("Deny").tag(PolicyDecision.deny)
                }
                .pickerStyle(.segmented)

                // A text field's Return saves the sheet, so hosts go in an
                // editor, one per line.
                Section("Hosts") {
                    TextEditor(text: $draft.resources)
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 88)
                        .overlay(alignment: .topLeading) {
                            if draft.resources.isEmpty {
                                Text("api.example.com\n*.example.com")
                                    .font(.body.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel("Hosts")
                }

                Section {
                    Picker("For", selection: $draft.sandbox) {
                        Text("All sandboxes").tag(String?.none)
                        if !scopeNames.isEmpty {
                            Divider()
                        }
                        ForEach(scopeNames, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    Picker("Protocol", selection: $draft.protocols) {
                        ForEach(NetworkRuleDraft.Protocols.allCases) { protocols in
                            Text(protocols.title).tag(protocols)
                        }
                    }
                } footer: {
                    if let error {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else {
                        Text(footer)
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
        .frame(minWidth: 460, idealWidth: 500, minHeight: 460, idealHeight: 500)
        .navigationTitle(draft.isEditing ? "Edit Network Rule" : "Add Network Rule")
    }

    /// The sandboxes to choose from, keeping the one being edited even if
    /// it's no longer listed.
    private var scopeNames: [String] {
        guard let sandbox = draft.sandbox, !sandboxNames.contains(sandbox) else { return sandboxNames }
        return [sandbox] + sandboxNames
    }

    private var footer: String {
        var text = "Put each host on its own line. Use *.example.com for subdomains, **.example.com for subdomains at any depth, an IP address or CIDR prefix, an optional port such as example.com:443, or ** for every host."
        if draft.protocols == .automatic {
            text += " By default, allow rules apply to TCP and deny rules to TCP and UDP."
        }
        return text
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            try await networkRules.save(draft)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}
