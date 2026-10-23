import SwiftUI

/// Checks whether a host is allowed with `sbx policy check`, by the global
/// policy or for one sandbox. Opened from Management › Network Rules, where
/// it starts with the global policy, and from a sandbox's page, where it
/// starts with that sandbox.
struct NetworkCheckSheet: View {
    /// The sandbox to check, or nil for the global policy.
    @State var sandbox: String? = nil
    @Environment(SandboxStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var protocols = NetworkRuleDraft.Protocols.automatic
    /// Most recent first, so checking several hosts in a row compares them.
    @State private var results: [NetworkCheckResult] = []
    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Host", text: $target, prompt: Text("api.example.com, host:port or a URL"))
                        .onSubmit { Task { await check() } }
                    Picker("For", selection: $sandbox) {
                        Text("All sandboxes").tag(String?.none)
                        if !scopeNames.isEmpty {
                            Divider()
                        }
                        ForEach(scopeNames, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    Picker("Protocol", selection: $protocols) {
                        ForEach([NetworkRuleDraft.Protocols.automatic, .tcp, .udp]) { protocols in
                            Text(protocols.title).tag(protocols)
                        }
                    }
                } footer: {
                    Text("All sandboxes checks the global policy, without rules for a single sandbox. Hosts without a port are checked on port 443, and a URL's path isn't checked.")
                        .foregroundStyle(.secondary)
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
                .disabled(isChecking || trimmedTarget.isEmpty)
                .help(trimmedTarget.isEmpty ? "Enter a host." : "")
            }
            .padding(20)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 380, idealHeight: 460)
        .navigationTitle("Check Host")
    }

    /// The sandboxes to choose from, keeping the one chosen even if it's no
    /// longer listed.
    private var scopeNames: [String] {
        let names = store.sandboxes.map(\.name)
        guard let sandbox, !names.contains(sandbox) else { return names }
        return [sandbox] + names
    }

    private var trimmedTarget: String {
        target.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func check() async {
        guard !trimmedTarget.isEmpty, !isChecking else { return }
        isChecking = true
        let result = await NetworkCheckResult.check(trimmedTarget, sandbox: sandbox, protocols: protocols)
        results.insert(result, at: 0)
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
                Text(result.target)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
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
        case .failed:
            Label("Couldn't Check", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    /// Where it was checked, the protocol and why, such as
    /// "All sandboxes · TCP · No matching allow rule (default deny)".
    private var details: String {
        var parts = [result.sandbox ?? "All sandboxes"]
        if let protocolName = result.protocolName {
            parts.append(protocolName)
        }
        switch result.outcome {
        case let .failed(message):
            parts.append(message)
        case .allowed, .denied:
            if let reason = result.reason {
                parts.append(reason)
            }
        }
        return parts.joined(separator: " · ")
    }
}
