import SwiftUI

/// The tabs of Management › Policies. The last one used is remembered.
enum PoliciesTab: String, CaseIterable, Identifiable {
    case network
    case filesystem

    static let selectionKey = "policiesTab"

    var id: Self { self }

    var title: String {
        switch self {
        case .network: "Network"
        case .filesystem: "File System"
        }
    }
}

/// Management › Policies: the network and file system rules for every
/// sandbox, then each sandbox's own, in a tab for each kind, with ways to
/// add, edit and remove the network rules added locally.
struct PoliciesView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(PolicyStore.self) private var policies
    @AppStorage(PoliciesTab.selectionKey) private var tab = PoliciesTab.network
    @State private var editor: NetworkRuleDraft?
    @State private var removal: NetworkRule?
    @State private var isCheckingHost = false

    var body: some View {
        TabView(selection: $tab) {
            ForEach(PoliciesTab.allCases) { tab in
                Tab(value: tab) {
                    Form {
                        switch tab {
                        case .network: networkSections
                        case .filesystem: filesystemSections
                        }
                    }
                    .formStyle(.grouped)
                } label: {
                    Text(tab.title)
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
        .navigationTitle("Policies")
        .task {
            await policies.refresh()
        }
        .toolbar {
            // File system rules can't be changed, so their tab has no actions.
            if tab == .network {
                ToolbarItemGroup {
                    Button("Check Host", systemImage: "checkmark.shield") {
                        isCheckingHost = true
                    }
                    .help("Check whether sandboxes may reach a host")
                    Button("Add Network Rule", systemImage: "plus") {
                        editor = NetworkRuleDraft()
                    }
                    .help("Allow or deny network access to hosts, for every sandbox or one")
                }
            }
        }
        .networkRuleEditing(editor: $editor, removal: $removal)
        .sheet(isPresented: $isCheckingHost) {
            NetworkCheckSheet()
        }
    }

    @ViewBuilder
    private var networkSections: some View {
        Section {
            if policies.globalNetworkRules.isEmpty {
                Text(policies.hasLoaded ? "No rules for all sandboxes." : "Loading…")
                    .foregroundStyle(.secondary)
            }
            ForEach(policies.globalNetworkRules) { rule in
                NetworkRuleRow(rule: rule, editor: $editor, removal: $removal)
            }
        } header: {
            Text("All Sandboxes")
        } footer: {
            if let error = policies.networkLoadError {
                Text("Couldn't list network rules: \(error)")
                    .foregroundStyle(.secondary)
            } else {
                Text("Deny rules take precedence over allow rules. Changes apply to running sandboxes straight away.")
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(policies.sandboxRules.filter { !$0.networkRules.isEmpty }) { group in
            Section {
                ForEach(group.networkRules) { rule in
                    NetworkRuleRow(rule: rule, editor: $editor, removal: $removal)
                }
            } header: {
                SandboxRulesHeader(name: group.sandbox)
            }
        }
    }

    @ViewBuilder
    private var filesystemSections: some View {
        Section {
            if policies.globalFilesystemRules.isEmpty {
                Text(policies.hasLoaded ? "No rules for all sandboxes." : "Loading…")
                    .foregroundStyle(.secondary)
            }
            ForEach(policies.globalFilesystemRules) { rule in
                FilesystemRuleRow(rule: rule)
            }
        } header: {
            Text("All Sandboxes")
        } footer: {
            if let error = policies.filesystemLoadError {
                Text("Couldn't list file system rules: \(error)")
                    .foregroundStyle(.secondary)
            } else {
                Text("These decide which folders on your Mac sandboxes can mount as a workspace. They're checked when a sandbox is created, and are set by the default policy or your organization.")
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(policies.sandboxRules.filter { !$0.filesystemRules.isEmpty }) { group in
            Section {
                ForEach(group.filesystemRules) { rule in
                    FilesystemRuleRow(rule: rule)
                }
            } header: {
                SandboxRulesHeader(name: group.sandbox)
            }
        }
    }
}

/// A sandbox's agent icon and name, over its own rules.
private struct SandboxRulesHeader: View {
    let name: String
    @Environment(SandboxStore.self) private var store

    var body: some View {
        let sandbox = store.sandboxes.first { $0.name == name }
        HStack(spacing: 5) {
            AgentIcon(agent: sandbox?.knownAgent, size: 12)
                .foregroundStyle(sandbox?.knownAgent?.color ?? .secondary)
            Text(name)
        }
    }
}

extension View {
    /// The sheet for adding or editing a network rule, and the confirmation
    /// for removing one. Failures to remove show through the policy store's `actionError`, in the main window.
    func networkRuleEditing(editor: Binding<NetworkRuleDraft?>, removal: Binding<NetworkRule?>) -> some View {
        modifier(NetworkRuleEditing(editor: editor, removal: removal))
    }
}

private struct NetworkRuleEditing: ViewModifier {
    @Binding var editor: NetworkRuleDraft?
    @Binding var removal: NetworkRule?
    @Environment(SandboxStore.self) private var store
    @Environment(PolicyStore.self) private var policies

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
                    Task { await policies.remove(rule) }
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
    @Environment(PolicyStore.self) private var policies

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
            if let badge {
                Text(badge.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
                    .help(badge.help)
            } else if policies.isRemoving(rule) {
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

    /// Shown in place of the buttons when the rule can't be changed here:
    /// where it comes from, or where it's managed.
    private var badge: (label: String, help: String)? {
        if rule.isLocal {
            return readOnlyLabel.map { (label: $0, help: "A rule for all sandboxes. Change it in Management › Policies.") }
        }
        if rule.source?.lowercased() == "org" {
            return (label: "Organization", help: "Set by your organization, so it can't be changed here.")
        }
        if rule.source?.lowercased() == "kit" || rule.name?.lowercased().hasPrefix("kit:") == true {
            return (label: "Kit", help: "Added for the sandbox's agent or kits when the sandbox was created. sbx doesn't allow changing it.")
        }
        return switch rule.createdVia?.lowercased() {
        case "default": (label: "Default", help: "Part of the default network policy. sbx doesn't allow changing it on its own.")
        case "provisioned": (label: "Provisioned", help: "Added by sbx when the sandbox was created. sbx doesn't allow changing it.")
        default: (label: "Read Only", help: "sbx doesn't allow changing this rule.")
        }
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
    @Environment(PolicyStore.self) private var policies
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
            try await policies.save(draft)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}
