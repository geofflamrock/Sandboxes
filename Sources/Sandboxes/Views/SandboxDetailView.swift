import SwiftUI

struct SandboxDetailView: View {
    let sandbox: Sandbox
    @Environment(SandboxStore.self) private var store
    @State private var network: SandboxNetwork?
    @State private var networkError: String?
    @State private var approvalResponse: ApprovalResponse?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AgentIcon(agent: sandbox.knownAgent, size: 28, filled: true)
                        .foregroundStyle(sandbox.knownAgent?.color ?? Color.accentColor)
                        .frame(width: 56, height: 56)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sandbox.name)
                            .font(.title2.bold())
                            .textSelection(.enabled)
                        StatusBadge(sandbox: sandbox)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("Details") {
                if let agent = sandbox.agent {
                    LabeledContent("Agent") {
                        Text(agent).textSelection(.enabled)
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
                LabeledContent("Network Policy") {
                    networkPolicy
                }
            }

            SandboxResourcesSection(sandbox: sandbox)
                .id(sandbox.name)

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
                    }
                } header: {
                    Text("Pending Approvals (\(approvals.count.formatted()))")
                } footer: {
                    Text("This sandbox tried to reach these destinations and was blocked until you respond.")
                        .foregroundStyle(.secondary)
                }
            }

            if let network {
                Section {
                    if network.rules.isEmpty {
                        Text("No rules apply to this sandbox.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(network.rules) { rule in
                        NetworkRuleRow(rule: rule)
                    }
                } header: {
                    Text("Network Rules (\(network.rules.count.formatted()))")
                } footer: {
                    if network.defaultDecision == .deny {
                        Text("Requests that no rule allows are blocked, or wait for your approval.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Network Traffic (\(network.log.count.formatted()))") {
                    if network.log.isEmpty {
                        Text("No requests yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(network.log) { entry in
                        NetworkLogRow(entry: entry)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: sandbox.name) {
            await refreshNetwork()
        }
        .confirmationDialog(
            approvalResponse?.question ?? "",
            isPresented: Binding(
                get: { approvalResponse != nil },
                set: { if !$0 { approvalResponse = nil } }
            ),
            presenting: approvalResponse
        ) { response in
            switch response.action {
            case let .approve(option):
                Button("Approve") {
                    Task { await store.respond(to: response.approval, with: option) }
                }
            case .deny:
                Button("Deny", role: .destructive) {
                    Task { await store.deny(response.approval, in: response.sandbox) }
                }
            }
        } message: { response in
            Text(response.message)
        }
        .navigationTitle(sandbox.name)
        .toolbar {
            ToolbarItemGroup {
                if store.isBusy(sandbox) {
                    ProgressView()
                        .controlSize(.small)
                }
                SandboxActionButtons(sandbox: sandbox, showsDivider: false)
                    .labelStyle(.iconOnly)
            }
        }
    }

    @ViewBuilder
    private var networkPolicy: some View {
        if let network {
            HStack(spacing: 6) {
                DecisionLabel(decision: network.defaultDecision, style: .policy)
                if let preset = network.presetLabel {
                    Text("(\(preset))").foregroundStyle(.secondary)
                }
            }
        } else if let networkError {
            Text("Unknown")
                .help("Couldn't read the network policy: \(networkError)")
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// Reads the network policy, rules and traffic from `sbx policy` every few
    /// seconds until the task is cancelled.
    private func refreshNetwork() async {
        network = nil
        networkError = nil
        while !Task.isCancelled {
            do {
                let latest = try await SandboxNetwork.fetch(for: sandbox)
                guard !Task.isCancelled else { return }
                if latest != network {
                    network = latest
                }
                networkError = nil
            } catch {
                guard !Task.isCancelled else { return }
                networkError = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(5))
        }
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
            Text("Resources")
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
                return
            }
            while !Task.isCancelled {
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

    /// Shows a spinner until the first sample arrives.
    @ViewBuilder
    private func value(_ text: String?) -> some View {
        if let text {
            Text(text).textSelection(.enabled)
        } else if usageError != nil {
            Text("Unknown")
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// A response to a pending approval, waiting for the user to confirm it.
private struct ApprovalResponse {
    enum Action {
        case approve(NetworkApproval.Option)
        case deny
    }

    let approval: NetworkApproval
    let sandbox: Sandbox
    let action: Action

    var question: String {
        switch action {
        case .approve: "Allow access to “\(approval.title)”?"
        case .deny: "Deny access to “\(approval.title)”?"
        }
    }

    var message: String {
        let effect: String
        var commands: [[String]]
        switch action {
        case let .approve(option):
            effect = "This adds a rule that lets “\(sandbox.name)” reach \(approval.title)."
            commands = [NetworkApproval.respondArguments(approval: approval, option: option)]
        case .deny:
            effect = "This adds a rule that blocks “\(sandbox.name)” from reaching \(approval.title), and dismisses the request."
            commands = [NetworkApproval.denyArguments(approval: approval, sandbox: sandbox.name)]
            if let dismiss = approval.dismissOption {
                commands.append(NetworkApproval.respondArguments(approval: approval, option: dismiss))
            }
        }
        let lines = commands.map { (["sbx"] + $0).joined(separator: " ") }
        return "\(effect)\n\nRuns:\n\(lines.joined(separator: "\n"))"
    }
}

private struct NetworkApprovalRow: View {
    enum Action {
        case approve(NetworkApproval.Option)
        case deny
        case dismiss(NetworkApproval.Option)
    }

    let approval: NetworkApproval
    let respond: (Action) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            Text(approval.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail = approval.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Deny") { respond(.deny) }
            if let option = approval.approveOption {
                Button("Approve") { respond(.approve(option)) }
                    .buttonStyle(.borderedProminent)
            }
            if let option = approval.dismissOption {
                Button("Dismiss", systemImage: "xmark") { respond(.dismiss(option)) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Dismiss this request. The sandbox asks again the next time it tries to reach \(approval.title).")
            }
        }
        .help([approval.title, approval.detail].compactMap { $0 }.joined(separator: "\n"))
    }
}

private struct NetworkRuleRow: View {
    let rule: NetworkRule

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            DecisionLabel(decision: rule.decision, style: .rule)
                .frame(width: 80, alignment: .leading)
            Text(target)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(origin)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .help(details)
    }

    /// The hosts, then any HTTP method and path, e.g. "api.github.com GET /repos/**".
    private var target: String {
        ([rule.resources.joined(separator: ", ")] + [rule.method, rule.path].compactMap { $0 }).joined(separator: " ")
    }

    private var details: String {
        var lines = ["\(rule.decision == .allow ? "Allow" : "Deny") \(rule.resources.joined(separator: ", "))"]
        if let method = rule.method { lines.append("Method: \(method)") }
        if let path = rule.path { lines.append("Path: \(path)") }
        if !origin.isEmpty { lines.append(origin) }
        return lines.joined(separator: "\n")
    }

    /// For example "Kit · This sandbox" or "Local · All sandboxes".
    private var origin: String {
        var parts: [String] = []
        if let source = rule.source, !source.isEmpty {
            parts.append(source.lowercased() == "org" ? "Organization" : source.capitalized)
        }
        if let appliesTo = rule.appliesTo?.lowercased() {
            if appliesTo == "all" || appliesTo == "global" {
                parts.append("All sandboxes")
            } else if appliesTo.hasPrefix("sandbox") {
                parts.append("This sandbox")
            }
        }
        return parts.joined(separator: " · ")
    }
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

private struct DecisionLabel: View {
    enum Style {
        /// "Allow" or "Deny"
        case policy
        /// "Allow" or "Deny"
        case rule
        /// "Allowed" or "Denied"
        case traffic
    }

    let decision: NetworkDecision
    let style: Style

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: decision == .allow ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(decision == .allow ? .green : .red)
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

struct StatusBadge: View {
    let sandbox: Sandbox

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(sandbox.state.color)
                .frame(width: 7, height: 7)
            Text(sandbox.statusLabel)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .glassEffect(.regular.tint(sandbox.state.color.opacity(0.25)), in: .capsule)
    }
}
