import SwiftUI

/// The tabs of the sandbox detail view. The last one used is remembered
/// across sandboxes, so watching traffic carries on when you switch.
enum SandboxDetailTab: String, CaseIterable, Identifiable {
    case overview
    case policies
    case traffic
    case secrets

    static let selectionKey = "sandboxDetailTab"

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .policies: "Policies"
        case .traffic: "Traffic"
        case .secrets: "Secrets"
        }
    }
}

struct SandboxDetailView: View {
    let sandbox: Sandbox
    @Environment(SandboxStore.self) private var store
    @AppStorage(SandboxDetailTab.selectionKey) private var tab = SandboxDetailTab.overview
    @State private var network: SandboxNetwork?
    @State private var networkError: String?
    @State private var filesystemRules: [FilesystemRule]?
    @State private var filesystemError: String?
    @State private var isLoadingPolicies = false
    @State private var approvalResponse: ApprovalResponse?
    @Environment(SecretStore.self) private var secrets
    @Environment(MCPServerStore.self) private var mcp
    @State private var secretEditor: SecretDraft?
    @State private var secretRemoval: SecretRemoval?
    @Environment(NetworkRuleStore.self) private var networkRules
    @State private var ruleEditor: NetworkRuleDraft?
    @State private var ruleRemoval: NetworkRule?

    // The policies are polled here rather than in the Policies and Traffic
    // tabs so both share one refresh and the approvals row on Overview stays
    // current.
    var body: some View {
        TabView(selection: $tab) {
            ForEach(SandboxDetailTab.allCases) { tab in
                Tab(value: tab) {
                    Form {
                        switch tab {
                        case .overview:
                            approvalsSummarySection
                            detailsSection
                            SandboxResourcesSection(sandbox: sandbox)
                                .id(sandbox.name)
                        case .policies:
                            approvalsSection
                            policySection
                            rulesSection
                            filesystemRulesSection
                        case .traffic:
                            trafficSection
                        case .secrets:
                            secretsSection
                        }
                    }
                    .formStyle(.grouped)
                } label: {
                    Text(tab.title)
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
        .onChange(of: store.approvalsToReveal, initial: true) { _, name in
            guard name == sandbox.name else { return }
            store.approvalsToReveal = nil
            tab = .policies
        }
        .task(id: sandbox.name) {
            await refreshPolicies()
        }
        .task(id: sandbox.name) {
            await secrets.refresh()
        }
        .approvalResponseDialog($approvalResponse)
        .secretEditing(editor: $secretEditor, removal: $secretRemoval)
        .networkRuleEditing(editor: $ruleEditor, removal: $ruleRemoval)
        // Show a rule added, changed or removed here or in Management
        // straight away, rather than at the next poll.
        .onChange(of: networkRules.rules) {
            Task { await reloadNetwork() }
        }
        .navigationTitle(sandbox.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Home", systemImage: "chevron.backward") {
                    store.selection = nil
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Home")
            }
            // Kept out of the actions' group so it doesn't widen it, and always
            // laid out so the toolbar doesn't shift when it appears.
            ToolbarItem {
                let isBusy = store.isBusy(sandbox) || mcp.isBusy(sandbox)
                ProgressView()
                    .controlSize(.small)
                    .opacity(isBusy ? 1 : 0)
                    .accessibilityHidden(!isBusy)
            }
            .sharedBackgroundVisibility(.hidden)
            // Left of the sandbox's actions, so they stay put as tabs change, and
            // after the spinner, whose space would otherwise leave a gap.
            if tab == .secrets {
                ToolbarItem {
                    Button("Add Secret", systemImage: "plus") {
                        secretEditor = SecretDraft(scope: .sandbox(sandbox.name))
                    }
                    .help("Store a secret for this sandbox")
                }
                // Without it, the button shares the Stop and Open Shell glass.
                ToolbarSpacer(.fixed)
            }
            if tab == .policies {
                ToolbarItem {
                    Button("Add Network Rule", systemImage: "plus") {
                        ruleEditor = NetworkRuleDraft(sandbox: sandbox.name)
                    }
                    .help("Allow or deny network access to hosts for this sandbox")
                }
                ToolbarSpacer(.fixed)
            }
            ToolbarItemGroup {
                SandboxActionButtons(sandbox: sandbox, placement: .toolbar)
                    .labelStyle(.iconOnly)
            }
        }
    }

    // MARK: - Overview

    /// Points to the Policies tab, where pending approvals are answered.
    @ViewBuilder
    private var approvalsSummarySection: some View {
        let count = store.approvals(for: sandbox).count
        if count > 0 {
            Section {
                HStack {
                    Label(
                        count == 1
                            ? "1 request is waiting for your approval."
                            : "\(count.formatted()) requests are waiting for your approval.",
                        systemImage: "hand.raised"
                    )
                    Spacer()
                    Button("Review") {
                        tab = .policies
                    }
                }
            }
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    StatusDot(color: sandbox.state.color)
                    Text(sandbox.statusLabel)
                }
            }
            if let agent = sandbox.agent {
                LabeledContent("Agent") {
                    HStack(spacing: 6) {
                        AgentIcon(agent: sandbox.knownAgent, size: 14)
                            .foregroundStyle(sandbox.knownAgent?.color ?? .secondary)
                        Text(agent).textSelection(.enabled)
                    }
                }
            }
            if let createdAt = sandbox.createdAt {
                LabeledContent("Created") {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text("\(DurationFormat.short(context.date.timeIntervalSince(createdAt))) ago (\(createdAt.formatted(date: .abbreviated, time: .shortened)))")
                            .textSelection(.enabled)
                    }
                }
            }
            LabeledContent(sandbox.workspaces.count > 1 ? "Workspaces" : "Workspace") {
                lines(sandbox.workspaces.map { ($0 as NSString).abbreviatingWithTildeInPath })
            }
            LabeledContent("Ports") {
                lines(sandbox.ports)
            }
        }
    }

    // MARK: - Policies

    @ViewBuilder
    private var approvalsSection: some View {
        let approvals = store.approvals(for: sandbox)
        if !approvals.isEmpty {
            Section {
                ForEach(approvals) { approval in
                    NetworkApprovalRow(approval: approval) { action in
                        switch action {
                        case let .approve(option):
                            approvalResponse = ApprovalResponse(approval: approval, sandbox: sandbox, action: .approve(option))
                        case .deny:
                            approvalResponse = ApprovalResponse(approval: approval, sandbox: sandbox, action: .deny)
                        case let .dismiss(option):
                            Task { await store.respond(to: approval, with: option) }
                        }
                    }
                    .disabled(store.isResponding(to: approval))
                }
            } header: {
                SectionHeader(
                    title: "Pending Approvals (\(approvals.count.formatted()))",
                    isLoading: approvals.contains { store.isResponding(to: $0) }
                )
            } footer: {
                Text("This sandbox tried to reach these destinations and was blocked until you respond.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var policySection: some View {
        Section {
            LabeledContent("Network Policy") {
                networkPolicy
            }
        } header: {
            SectionHeader(title: "Policy", isLoading: isLoadingPolicies)
        } footer: {
            if let networkError {
                Text("Couldn't read the network policy: \(networkError)")
                    .foregroundStyle(.secondary)
            } else if network?.defaultDecision == .deny {
                Text("Requests that no rule allows are blocked, or wait for your approval.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Rules scoped to this sandbox, which can be changed here, then the
    /// others that apply to it, which are changed in Management › Network
    /// Rules or set by a kit or organization.
    private var rulesSection: some View {
        Section {
            if network == nil {
                networkPlaceholder
            }
            if let network {
                let scoped = network.rules.filter { $0.sandboxName == sandbox.name }
                let others = network.rules.filter { $0.sandboxName != sandbox.name }
                if network.rules.isEmpty {
                    Text("No rules apply to this sandbox.")
                        .foregroundStyle(.secondary)
                }
                ForEach(scoped) { rule in
                    NetworkRuleRow(rule: rule, editor: $ruleEditor, removal: $ruleRemoval)
                }
                ForEach(others) { rule in
                    NetworkRuleRow(rule: rule, editor: .constant(nil), removal: .constant(nil), readOnlyLabel: "Global")
                }
            }
        } header: {
            SectionHeader(title: "Network Rules", count: network?.rules.count, isLoading: isLoadingPolicies)
        } footer: {
            HStack(spacing: 4) {
                Text("Rules for this sandbox apply alongside rules for all sandboxes, and deny rules take precedence.")
                    .foregroundStyle(.secondary)
                Button("Manage Network Rules") {
                    store.selection = .networkRules
                }
                .buttonStyle(.link)
            }
        }
    }

    private var filesystemRulesSection: some View {
        Section {
            if let filesystemRules {
                if filesystemRules.isEmpty {
                    Text("No rules apply to this sandbox.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filesystemRules) { rule in
                    FilesystemRuleRow(rule: rule)
                }
            } else {
                Text(filesystemError == nil ? "Loading…" : "Unknown")
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionHeader(title: "File System Rules", count: filesystemRules?.count, isLoading: isLoadingPolicies)
        } footer: {
            if let filesystemError {
                Text("Couldn't read the file system policy: \(filesystemError)")
                    .foregroundStyle(.secondary)
            } else {
                Text("These decide which folders on your Mac the sandbox can mount as a workspace. They're checked when the sandbox is created, and are set by the default policy or your organization.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Traffic

    private var trafficSection: some View {
        Section {
            if network == nil {
                networkPlaceholder
            }
            if let network {
                if network.log.isEmpty {
                    Text("No requests yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(network.log) { entry in
                    NetworkLogRow(entry: entry)
                }
            }
        } header: {
            SectionHeader(title: "Network Traffic", count: network?.log.count, isLoading: isLoadingPolicies)
        } footer: {
            if let networkError {
                Text("Couldn't read the network traffic: \(networkError)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Secrets

    /// Secrets scoped to this sandbox, which can be changed here, then the
    /// global ones, which are changed in Management › Secrets. Host-only
    /// registry credentials aren't given to sandboxes, so aren't listed.
    private var secretsSection: some View {
        let scoped = secrets.secrets(for: sandbox.name)
        let global = secrets.globalSecrets.filter { $0.scope == .global }
        let count = scoped.count + global.count
        return Section {
            if count == 0 {
                Text(secrets.hasLoaded ? "No secrets." : "Loading…")
                    .foregroundStyle(.secondary)
            }
            ForEach(scoped) { secret in
                SecretRow(secret: secret, editor: $secretEditor, removal: $secretRemoval)
            }
            ForEach(global) { secret in
                SecretRow(
                    secret: secret,
                    editor: .constant(nil),
                    removal: .constant(nil),
                    readOnlyLabel: "Global",
                    isOverridden: scoped.contains { $0.kind == secret.kind && $0.name == secret.name }
                )
            }
        } header: {
            Text(count == 0 ? "Secrets" : "Secrets (\(count.formatted()))")
        } footer: {
            HStack(spacing: 4) {
                Text("Secrets for this sandbox override global secrets for the same service.")
                    .foregroundStyle(.secondary)
                Button("Manage Secrets") {
                    store.selection = .secrets
                }
                .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private var networkPolicy: some View {
        if let network {
            DecisionLabel(decision: network.defaultDecision, style: .policy, detail: network.presetLabel)
        } else if networkError != nil {
            Text("Unknown")
        }
    }

    /// A row for the network sections until the first fetch finishes. A
    /// section with no rows draws its header in a smaller style.
    private var networkPlaceholder: some View {
        Text(networkError == nil ? "Loading…" : "Unknown")
            .foregroundStyle(.secondary)
    }

    /// Reads the network policy, rules and traffic, and the file system rules,
    /// from `sbx policy` every few seconds until the task is cancelled. Each
    /// reports its own failure, so one that fails doesn't hide the other.
    private func refreshPolicies() async {
        network = nil
        networkError = nil
        filesystemRules = nil
        filesystemError = nil
        isLoadingPolicies = false
        let sandbox = sandbox
        while !Task.isCancelled {
            isLoadingPolicies = true
            async let latestNetwork = SandboxNetwork.fetch(for: sandbox)
            async let latestFilesystemRules = FilesystemRule.fetch(for: sandbox)
            do {
                let latest = try await latestNetwork
                guard !Task.isCancelled else { return }
                if latest != network {
                    network = latest
                }
                networkError = nil
            } catch {
                guard !Task.isCancelled else { return }
                networkError = error.localizedDescription
            }
            do {
                let latest = try await latestFilesystemRules
                guard !Task.isCancelled else { return }
                if latest != filesystemRules {
                    filesystemRules = latest
                }
                filesystemError = nil
            } catch {
                guard !Task.isCancelled else { return }
                filesystemError = error.localizedDescription
            }
            isLoadingPolicies = false
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Reads the network policy, rules and traffic once, such as after a
    /// rule changes.
    private func reloadNetwork() async {
        guard let latest = try? await SandboxNetwork.fetch(for: sandbox), latest != network else { return }
        network = latest
        networkError = nil
    }

    @ViewBuilder
    private func lines(_ values: [String]) -> some View {
        if values.isEmpty {
            Text("None")
        } else {
            VStack(alignment: .trailing) {
                ForEach(values, id: \.self) { value in
                    Text(value).textSelection(.enabled)
                }
            }
        }
    }
}

/// CPU, memory, disk and uptime. Limits come from `sbx ls`; usage is sampled
/// every few seconds while the sandbox is running.
private struct SandboxResourcesSection: View {
    let sandbox: Sandbox
    @State private var usage: SandboxUsage?
    @State private var usageError: String?
    @State private var isLoadingUsage = false

    private var isRunning: Bool { sandbox.state == .running }

    var body: some View {
        Section {
            LabeledContent("CPUs") {
                value(cpuText)
            }
            LabeledContent("Memory") {
                value(amount(used: usage?.memoryUsed, total: usage?.memoryTotal ?? sandbox.memoryBytes, style: .memory))
            }
            if isRunning {
                LabeledContent("Disk") {
                    value(amount(used: usage?.diskUsed, total: usage?.diskTotal, style: .file))
                }
                LabeledContent("Uptime") {
                    value(usage?.uptime.map(DurationFormat.short))
                }
            }
        } header: {
            SectionHeader(title: "Resources", isLoading: isLoadingUsage)
        } footer: {
            if let usageError {
                Text("Couldn't read resource usage: \(usageError)")
                    .foregroundStyle(.secondary)
            } else if !isRunning {
                Text("Usage, disk and uptime are shown while the sandbox is running.")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: isRunning) {
            guard isRunning else {
                usage = nil
                usageError = nil
                isLoadingUsage = false
                return
            }
            while !Task.isCancelled {
                isLoadingUsage = true
                do {
                    let sample = try await SandboxUsage.fetch(for: sandbox)
                    guard !Task.isCancelled else { return }
                    usage = sample
                    usageError = nil
                } catch {
                    // Cancelling terminates sbx exec, which reports a failure.
                    guard !Task.isCancelled else { return }
                    usageError = error.localizedDescription
                }
                isLoadingUsage = false
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var cpuText: String? {
        let count = sandbox.cpus.map { $0.formatted() } ?? usage?.cpuCount.map { String($0) }
        guard let count else { return isRunning ? nil : "Unknown" }
        guard let percent = usage?.cpuPercent else { return count }
        return "\(count) (\(percent.formatted(.number.precision(.fractionLength(0))))%)"
    }

    private func amount(used: Int64?, total: Int64?, style: ByteCountFormatStyle.Style) -> String? {
        let format = ByteCountFormatStyle(style: style)
        switch (used, total) {
        case let (used?, total?):
            return "\(used.formatted(format)) / \(total.formatted(format))"
        case let (nil, total?):
            return total.formatted(format)
        default:
            return isRunning ? nil : "Unknown"
        }
    }

    /// Empty until the first sample arrives; the header shows a spinner.
    @ViewBuilder
    private func value(_ text: String?) -> some View {
        if let text {
            Text(text).textSelection(.enabled)
        } else if usageError != nil {
            Text("Unknown")
        }
    }
}

/// A section title, with an optional count in brackets, and a spinner when
/// loading the section's data or running an action takes more than a moment.
private struct SectionHeader: View {
    let title: String
    var count: Int?
    let isLoading: Bool
    @State private var showsSpinner = false

    var body: some View {
        HStack(spacing: 6) {
            if let count {
                Text("\(title) (\(count.formatted()))")
            } else {
                Text(title)
            }
            if showsSpinner {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .task(id: isLoading) {
            guard isLoading else {
                showsSpinner = false
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(600))
                showsSpinner = true
            } catch {
                // Loading finished before the delay was up.
            }
        }
    }
}

private struct FilesystemRuleRow: View {
    let rule: FilesystemRule

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            DecisionLabel(decision: rule.decision, style: .rule)
                .frame(width: 80, alignment: .leading)
            Text(rule.paths.joined(separator: ", "))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text([access, origin].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .help(details)
    }

    /// "Read", "Write" or "Read & Write", or nil if sbx doesn't say.
    private var access: String? {
        switch (rule.access.contains(.read), rule.access.contains(.write)) {
        case (true, true): "Read & Write"
        case (true, false): "Read"
        case (false, true): "Write"
        case (false, false): nil
        }
    }

    private var details: String {
        var lines = ["\(rule.decision == .allow ? "Allow" : "Deny") \(rule.paths.joined(separator: ", "))"]
        if let access { lines.append("Access: \(access)") }
        if !origin.isEmpty { lines.append(origin) }
        return lines.joined(separator: "\n")
    }

    private var origin: String {
        ruleOrigin(source: rule.source, appliesTo: rule.appliesTo)
    }
}

/// Where a rule came from and what it applies to, for example
/// "Kit · This sandbox" or "Local · All sandboxes".
private func ruleOrigin(source: String?, appliesTo: String?) -> String {
    var parts: [String] = []
    if let source, !source.isEmpty {
        parts.append(source.lowercased() == "org" ? "Organization" : source.capitalized)
    }
    if let appliesTo = appliesTo?.lowercased() {
        if appliesTo == "all" || appliesTo == "global" {
            parts.append("All sandboxes")
        } else if appliesTo.hasPrefix("sandbox") {
            parts.append("This sandbox")
        }
    }
    return parts.joined(separator: " · ")
}

private struct NetworkLogRow: View {
    let entry: NetworkLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            DecisionLabel(decision: entry.decision, style: .traffic)
                .frame(width: 100, alignment: .leading)
            Text(entry.host)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.host)
            Spacer()
            Text(entry.count == 1 ? "1 request" : "\(entry.count.formatted()) requests")
                .monospacedDigit()
            if let lastSeen = entry.lastSeen {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("\(DurationFormat.short(context.date.timeIntervalSince(lastSeen))) ago")
                        .foregroundStyle(.secondary)
                        .help(lastSeen.formatted(date: .abbreviated, time: .standard))
                }
                .frame(minWidth: 64, alignment: .trailing)
            }
        }
    }
}

struct DecisionLabel: View {
    enum Style {
        /// "Allow" or "Deny"
        case policy
        /// "Allow" or "Deny"
        case rule
        /// "Allowed" or "Denied"
        case traffic
    }

    let decision: PolicyDecision
    let style: Style
    /// Shown in parentheses after the decision, e.g. "Allow (Balanced)".
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: decision == .allow ? .green : .red)
            Text(detail.map { "\(text) (\($0))" } ?? text)
        }
    }

    private var text: String {
        switch (decision, style) {
        case (.allow, .traffic): "Allowed"
        case (.deny, .traffic): "Denied"
        case (.allow, _): "Allow"
        case (.deny, _): "Deny"
        }
    }
}

/// A small coloured circle for a sandbox state or policy decision.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}
