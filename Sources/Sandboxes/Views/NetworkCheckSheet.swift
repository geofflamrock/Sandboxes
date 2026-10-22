import SwiftUI

/// Checks whether sandboxes may reach a host with `sbx policy check`, for
/// every sandbox or chosen ones. Opened from Management › Network Rules,
/// checking all sandboxes, and from a sandbox's page, checking that one.
struct NetworkCheckSheet: View {
    /// The sandbox to check to begin with, or nil to check all of them.
    var sandbox: String?
    @Environment(SandboxStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var protocols = NetworkRuleDraft.Protocols.automatic
    @State private var checksAll = true
    @State private var chosen: Set<String> = []
    @State private var results: [NetworkCheckResult] = []
    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Host", text: $target, prompt: Text("api.example.com, host:port or a URL"))
                        .onSubmit { Task { await check() } }
                    Picker("Protocol", selection: $protocols) {
                        ForEach([NetworkRuleDraft.Protocols.automatic, .tcp, .udp]) { protocols in
                            Text(protocols.title).tag(protocols)
                        }
                    }
                } footer: {
                    Text("Hosts without a port are checked on port 443. A URL's path isn't checked.")
                        .foregroundStyle(.secondary)
                }

                if !sandboxNames.isEmpty {
                    Section("Sandboxes") {
                        Picker("Check", selection: $checksAll) {
                            Text("All Sandboxes").tag(true)
                            Text("Chosen Sandboxes").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if !checksAll {
                            ForEach(sandboxNames, id: \.self) { name in
                                Toggle(name, isOn: Binding(
                                    get: { chosen.contains(name) },
                                    set: { isOn in
                                        if isOn { chosen.insert(name) } else { chosen.remove(name) }
                                    }
                                ))
                            }
                        }
                    }
                }

                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { result in
                            NetworkCheckRow(result: result)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            // Sheets separate their buttons from the content with a line.
            Divider()

            HStack {
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Done", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Check") {
                    Task { await check() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(isChecking || missing != nil)
                .help(missing ?? "")
            }
            .padding(20)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 420, idealHeight: 520)
        .navigationTitle("Check Host")
        .onAppear {
            if let sandbox {
                checksAll = false
                chosen = [sandbox]
            }
        }
    }

    /// The sandboxes to choose from, keeping the one the sheet was opened
    /// for even if it's no longer listed.
    private var sandboxNames: [String] {
        let names = store.sandboxes.map(\.name)
        guard let sandbox, !names.contains(sandbox) else { return names }
        return [sandbox] + names
    }

    private var trimmedTarget: String {
        target.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why it can't check yet, or nil when it can.
    private var missing: String? {
        if trimmedTarget.isEmpty {
            return "Enter a host."
        }
        if !sandboxNames.isEmpty && !checksAll && chosen.isEmpty {
            return "Choose at least one sandbox."
        }
        return nil
    }

    /// Checks each sandbox at once. With no sandboxes, checks the global
    /// policy instead.
    private func check() async {
        guard missing == nil, !isChecking else { return }
        let target = trimmedTarget
        let protocols = protocols
        let sandboxes: [String?] = sandboxNames.isEmpty
            ? [nil]
            : sandboxNames.filter { checksAll || chosen.contains($0) }
        isChecking = true
        let checked = await withTaskGroup(of: NetworkCheckResult.self) { group in
            for sandbox in sandboxes {
                group.addTask {
                    await NetworkCheckResult.check(target, sandbox: sandbox, protocols: protocols)
                }
            }
            return await group.reduce(into: [NetworkCheckResult]()) { $0.append($1) }
        }
        results = checked.sorted { ($0.sandbox ?? "").localizedStandardCompare($1.sandbox ?? "") == .orderedAscending }
        isChecking = false
    }
}

private struct NetworkCheckRow: View {
    let result: NetworkCheckResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            outcome
                .frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.sandbox ?? "Global policy")
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var outcome: some View {
        switch result.outcome {
        case .allowed:
            DecisionLabel(decision: .allow, style: .traffic)
        case .denied:
            DecisionLabel(decision: .deny, style: .traffic)
        case let .other(text):
            HStack(spacing: 6) {
                StatusDot(color: .orange)
                Text(text)
                    .lineLimit(1)
            }
            .help(text)
        case .failed:
            Label("Couldn't Check", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    private var detail: String? {
        if case let .failed(message) = result.outcome {
            return message
        }
        return result.detail
    }
}
