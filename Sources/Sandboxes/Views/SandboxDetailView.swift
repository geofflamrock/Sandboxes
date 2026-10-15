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
