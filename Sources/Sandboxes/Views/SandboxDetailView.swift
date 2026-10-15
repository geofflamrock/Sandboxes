import SwiftUI

struct SandboxDetailView: View {
    let sandbox: Sandbox
    @Environment(SandboxStore.self) private var store

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
            }

            SandboxResourcesSection(sandbox: sandbox)
                .id(sandbox.name)

            // Not given an `.id` like the resources section: two siblings with
            // the same id confuse the Form's row identity.
            SandboxNetworkSection(sandbox: sandbox)
        }
        .formStyle(.grouped)
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

/// The network policy, the rules that apply to the sandbox and the hosts it
/// has contacted, from `sbx policy`. Refreshed every few seconds.
private struct SandboxNetworkSection: View {
    let sandbox: Sandbox
    @State private var network: SandboxNetwork?
    @State private var networkError: String?

    var body: some View {
        Section {
            LabeledContent("Policy") {
                if let network {
                    HStack(spacing: 6) {
                        DecisionLabel(decision: network.defaultDecision, style: .policy)
                        if let preset = network.presetLabel {
                            Text("(\(preset))").foregroundStyle(.secondary)
                        }
                    }
                } else if networkError != nil {
                    Text("Unknown")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if let network {
                LabeledContent("Rules") {
                    Text(network.rules.isEmpty ? "None" : network.rules.count.formatted())
                }
                ForEach(network.rules) { rule in
                    NetworkRuleRow(rule: rule)
                }
                LabeledContent("Traffic") {
                    Text(network.log.isEmpty ? "No requests yet" : network.log.count == 1 ? "1 host" : "\(network.log.count.formatted()) hosts")
                }
                ForEach(network.log) { entry in
                    NetworkLogRow(entry: entry)
                }
            }
        } header: {
            Text("Network")
        } footer: {
            if let networkError {
                Text("Couldn't read the network policy: \(networkError)")
                    .foregroundStyle(.secondary)
            } else if network?.defaultDecision == .deny {
                Text("Requests that no rule allows are blocked, or wait for your approval.")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: sandbox.name) {
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
