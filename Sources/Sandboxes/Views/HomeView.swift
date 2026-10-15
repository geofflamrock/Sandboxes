import SwiftUI
import AppKit

/// Shown when no sandbox is selected: requests waiting for approval across
/// every sandbox, and shortcuts for creating a sandbox.
struct HomeView: View {
    @Environment(SandboxStore.self) private var store
    @State private var approvalResponse: ApprovalResponse?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HomeHeader {
                        withAnimation { proxy.scrollTo(HomeAnchor.approvals, anchor: .top) }
                    }
                    PendingApprovalsCard(approvalResponse: $approvalResponse)
                        .id(HomeAnchor.approvals)
                    QuickCreateSection()
                }
                .frame(maxWidth: 880, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .approvalResponseDialog($approvalResponse)
        // The page has its own large title, so keep the window title for the
        // Window menu and Mission Control but don't repeat it in the toolbar.
        .navigationTitle("Sandboxes")
        .toolbar(removing: .title)
    }
}

private enum HomeAnchor: Hashable {
    case approvals
}

/// The app icon, a large title and a line summarizing the sandboxes, or a
/// friendlier line when there aren't any yet.
private struct HomeHeader: View {
    let showApprovals: () -> Void
    @Environment(SandboxStore.self) private var store

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            // No extra spacing: the large title's line already leaves room for
            // descenders, which "Sandboxes" doesn't have.
            VStack(alignment: .leading, spacing: 0) {
                Text(store.hasLoaded && store.sandboxes.isEmpty && store.loadError == nil ? "No sandboxes yet" : "Sandboxes")
                    .font(.largeTitle.bold())
                summary
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if !store.hasLoaded {
            Text("Loading…")
        } else if store.sandboxes.isEmpty {
            if store.loadError != nil {
                Text("Couldn't load your sandboxes.")
            } else {
                Text("Pick an agent below to create your first one.")
            }
        } else {
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Text("·")
                    }
                    item
                }
            }
        }
    }

    /// One entry per state that has sandboxes, then pending approvals.
    private var items: [AnyView] {
        let states: [(SandboxState, String)] = [
            (.running, "running"),
            (.transitioning, "starting or stopping"),
            (.stopped, "stopped"),
            (.failed, "failed"),
            (.unknown, "unknown"),
        ]
        var items: [AnyView] = states.compactMap { state, label in
            let count = store.sandboxes.filter { $0.state == state }.count
            guard count > 0 else { return nil }
            return AnyView(
                HStack(spacing: 5) {
                    StatusDot(color: state.color)
                    Text("\(count.formatted()) \(label)")
                }
            )
        }
        if !store.approvals.isEmpty {
            let count = store.approvals.count
            items.append(AnyView(
                Button(action: showApprovals) {
                    Label("\(count.formatted()) waiting for approval", systemImage: "hand.raised.fill")
                        .labelStyle(SummaryLabelStyle())
                }
                .buttonStyle(.plain)
                .help("Show pending approvals")
            ))
        }
        return items
    }
}

/// An orange icon next to text in the summary's secondary style.
private struct SummaryLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .foregroundStyle(.orange)
            configuration.title
        }
    }
}

private struct HomeSectionHeader: View {
    let title: String
    var isLoading = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

/// A rounded panel with the same fill and border as the agent tiles.
private struct CardBackground: ViewModifier {
    var isHighlighted = false

    func body(content: Content) -> some View {
        content
            .background(Color.secondary.opacity(isHighlighted ? 0.12 : 0.05), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.25))
            }
    }
}

// MARK: - Pending approvals

private struct PendingApprovalsCard: View {
    @Binding var approvalResponse: ApprovalResponse?
    @Environment(SandboxStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeader(
                title: store.approvals.isEmpty ? "Pending Approvals" : "Pending Approvals (\(store.approvals.count.formatted()))",
                isLoading: store.approvals.contains { store.isResponding(to: $0) }
            )

            VStack(alignment: .leading, spacing: 0) {
                if store.approvals.isEmpty {
                    Label("No sandboxes are waiting for network access.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .padding(14)
                }
                ForEach(Array(store.approvals.enumerated()), id: \.element.id) { index, approval in
                    if index > 0 {
                        Divider()
                            .padding(.leading, 14)
                    }
                    row(for: approval)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CardBackground())

            if !store.approvals.isEmpty {
                Text("These sandboxes tried to reach these destinations and were blocked until you respond.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(for approval: NetworkApproval) -> some View {
        let sandbox = store.sandboxes.first { $0.name == approval.sandbox }
        return VStack(alignment: .leading, spacing: 6) {
            if let name = approval.sandbox {
                Button {
                    store.selection = sandbox?.id
                } label: {
                    HStack(spacing: 5) {
                        AgentIcon(agent: sandbox?.knownAgent, size: 12)
                            .foregroundStyle(sandbox?.knownAgent?.color ?? .secondary)
                        Text(name)
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(sandbox == nil)
                .help("Show “\(name)”")
            }
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
    }
}

// MARK: - Quick create

private struct QuickCreateSection: View {
    @Environment(SandboxStore.self) private var store
    @Environment(RecentsStore.self) private var recents

    private static let maxRecents = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeader(title: "Create a Sandbox")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(workloads, id: \.self) { workload in
                    QuickCreateCard(workload: workload) {
                        store.presentCreate(workload: workload)
                    }
                }
                QuickCreateCard(workload: nil) {
                    store.presentCreate()
                }
            }
        }
    }

    /// The most recently used workloads, one per agent. Before anything has
    /// been created, the first few agents Docker publishes kits for.
    private var workloads: [String] {
        guard !recents.workloads.isEmpty else {
            return Agent.creatable.prefix(3).compactMap(\.workloadImage)
        }
        var seenAgents: Set<String> = []
        var result: [String] = []
        for workload in recents.workloads {
            // Different spellings of the same kit (a tag, a registry prefix)
            // collapse into one card.
            let key = QuickCreateCard.agent(for: workload)?.displayName ?? workload
            guard seenAgents.insert(key).inserted else { continue }
            result.append(workload)
            if result.count == Self.maxRecents { break }
        }
        return result
    }
}

/// A card that opens the create sheet with `workload`, or a blank card for a
/// new sandbox when it's nil.
private struct QuickCreateCard: View {
    let workload: String?
    let action: () -> Void

    @State private var isHovering = false

    static func agent(for workload: String) -> Agent? {
        Agent(workloadImage: workload) ?? Agent(identifier: workload)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon
                    .frame(width: 40, height: 40)
                    .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if let workload {
                        Text(workload)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CardBackground(isHighlighted: isHovering))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(workload.map { "Create a sandbox with \($0)" } ?? "Create a sandbox with any agent, kits and workspace")
    }

    private var agent: Agent? {
        workload.flatMap(Self.agent(for:))
    }

    @ViewBuilder
    private var icon: some View {
        if workload == nil {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
        } else {
            AgentIcon(agent: agent, size: 22, filled: true)
                .foregroundStyle(agent?.color ?? Color.primary)
        }
    }

    private var title: String {
        guard let workload else { return "New Sandbox" }
        return agent?.displayName ?? Self.shortName(workload)
    }

    /// The image's repository name without registry, namespace or tag, e.g.
    /// `my-kit` for `ghcr.io/me/my-kit:1.0`.
    private static func shortName(_ image: String) -> String {
        var name = Substring(image)
        if let at = name.firstIndex(of: "@") { name = name[..<at] }
        if let slash = name.lastIndex(of: "/") { name = name[name.index(after: slash)...] }
        if let colon = name.firstIndex(of: ":") { name = name[..<colon] }
        return name.isEmpty ? image : String(name)
    }
}
