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
                LabeledContent("Status", value: sandbox.statusLabel)
                if let agent = sandbox.agent {
                    LabeledContent("Agent") {
                        Text(agent).textSelection(.enabled)
                    }
                }
                LabeledContent("Workspace") {
                    if sandbox.workspaces.isEmpty {
                        Text("None")
                    } else {
                        VStack(alignment: .trailing) {
                            ForEach(sandbox.workspaces, id: \.self) { path in
                                Text((path as NSString).abbreviatingWithTildeInPath)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
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
