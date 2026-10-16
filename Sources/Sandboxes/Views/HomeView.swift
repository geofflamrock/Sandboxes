import SwiftUI
import AppKit

/// Shown when no sandbox is selected: requests waiting for approval across
/// every sandbox, shortcuts for creating a sandbox, and the installed sbx.
struct HomeView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(SbxStatus.self) private var sbxStatus
    @State private var approvalResponse: ApprovalResponse?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HomeHeader {
                        withAnimation { proxy.scrollTo(HomeAnchor.approvals, anchor: .top) }
                    }
                    // At the top when sbx needs installing or upgrading,
                    // otherwise out of the way at the bottom.
                    if sbxStatus.needsAttention {
                        SbxStatusSection()
                    }
                    PendingApprovalsCard(approvalResponse: $approvalResponse)
                        .id(HomeAnchor.approvals)
                    QuickCreateSection()
                    if !sbxStatus.needsAttention {
                        SbxStatusSection()
                    }
                }
                .frame(maxWidth: 880, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .approvalResponseDialog($approvalResponse)
        .task { await checkSbx() }
        // The user installs or upgrades sbx in their terminal, so look again
        // when they come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checkSbx() }
        }
        // The page has its own large title, so keep the window title for the
        // Window menu and Mission Control but don't repeat it in the toolbar.
        .navigationTitle("Sandboxes")
        .toolbar(removing: .title)
    }

    private func checkSbx() async {
        if await sbxStatus.check() {
            // It was just installed, so the sandboxes can load now.
            await store.refresh()
        }
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

// MARK: - sbx

/// Which sbx is installed and the results of `sbx diagnose`, or the command
/// to install or upgrade it. The user runs the command themselves.
private struct SbxStatusSection: View {
    @Environment(SbxStatus.self) private var sbxStatus
    @Environment(SandboxStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeader(title: "sbx Health", isLoading: sbxStatus.isDiagnosing)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CardBackground())
        }
    }

    @ViewBuilder
    private var content: some View {
        switch sbxStatus.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Looking for sbx…")
                    .foregroundStyle(.secondary)
            }
        case .notInstalled:
            Label("sbx isn't installed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .symbolRenderingMode(.multicolor)
            Text("Sandboxes uses the Docker Sandboxes command line tool, sbx. Install it with Homebrew by running this in Terminal:")
                .foregroundStyle(.secondary)
            CopyableCommand(command: SbxStatus.installCommand)
            HStack(spacing: 16) {
                Link("Download from GitHub", destination: SbxStatus.releasesURL)
                SettingsLink { Text("Already installed? Set its location in Settings…") }
                    .buttonStyle(.link)
            }
            .font(.callout)
        case let .installed(installation):
            if let upgrade = sbxStatus.availableUpgrade {
                upgradeContent(installation, to: upgrade)
            } else {
                installedContent(installation)
            }
            Divider()
            SbxDiagnosticsView()
        }
    }

    private func upgradeContent(_ installation: SbxStatus.Installation, to upgrade: SbxStatus.Release) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("sbx \(upgrade.version) is available", systemImage: "arrow.up.circle.fill")
                .font(.headline)
                .foregroundStyle(.tint)
            if let command = installation.upgradeCommand {
                Text("You have \(installation.version.map(String.init(describing:)) ?? "an older version"). Upgrade it by running this in Terminal:")
                    .foregroundStyle(.secondary)
                CopyableCommand(command: command)
            } else {
                Text("You have \(installation.version.map(String.init(describing:)) ?? "an older version"), which wasn't installed with Homebrew. Download the new version from GitHub.")
                    .foregroundStyle(.secondary)
            }
            if store.sandboxes.contains(where: { $0.state == .running }) {
                Label("Upgrading stops the sbx daemon, so your running sandboxes will stop.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Link(installation.upgradeCommand == nil ? "Download from GitHub" : "Release notes", destination: upgrade.url)
                .font(.callout)
        }
    }

    private func installedContent(_ installation: SbxStatus.Installation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(installation.version.map { "sbx \($0)" } ?? "sbx")
                    .font(.headline)
                Text(installation.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Text(summary(installation))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(_ installation: SbxStatus.Installation) -> String {
        if installation.version == nil {
            return "Unknown version"
        }
        return sbxStatus.latest == nil ? "Installed" : "Up to date"
    }
}

/// A summary of the `sbx diagnose` checks. Failures and warnings are always
/// listed with what to do about them; passed checks are behind a disclosure.
private struct SbxDiagnosticsView: View {
    @Environment(SbxStatus.self) private var sbxStatus
    @State private var isShowingAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                summary
                Spacer(minLength: 0)
                Button("Run Again") {
                    Task { await sbxStatus.diagnose() }
                }
                .disabled(sbxStatus.isDiagnosing)
                .help("Run sbx diagnose again")
            }

            if let diagnostics = sbxStatus.diagnostics {
                let needsAttention = diagnostics.checks.filter { $0.status == .fail || $0.status == .warn }
                ForEach(needsAttention) { check in
                    SbxDiagnosticRow(check: check)
                }
                let others = diagnostics.checks.filter { $0.status == .pass || $0.status == .skip }
                if !others.isEmpty {
                    DisclosureGroup(isExpanded: $isShowingAll) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Self.grouped(others), id: \.offset) { _, group in
                                if let category = group.category {
                                    Text(category)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                }
                                ForEach(group.checks) { check in
                                    SbxDiagnosticRow(check: check)
                                }
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(needsAttention.isEmpty ? "Show all checks" : "Show passed checks")
                            .font(.callout)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let diagnostics = sbxStatus.diagnostics {
            let failed = diagnostics.count(.fail)
            let warned = diagnostics.count(.warn)
            let passed = diagnostics.count(.pass)
            let status: SbxDiagnostics.Check.Status = failed > 0 ? .fail : warned > 0 ? .warn : .pass
            Label {
                if failed == 0 && warned == 0 {
                    Text(diagnostics.checks.count == 1 ? "The diagnostic check passed" : "All \(passed.formatted()) diagnostic checks passed")
                } else {
                    Text(Self.counts(failed: failed, warned: warned, passed: passed))
                }
            } icon: {
                SbxStatusIcon(status: status)
            }
            .font(.headline)
        } else if let error = sbxStatus.diagnosticsError {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn't run sbx diagnose")
                        .font(.headline)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } icon: {
                SbxStatusIcon(status: .fail)
            }
        } else {
            Text(sbxStatus.isDiagnosing ? "Running sbx diagnose…" : "sbx diagnose hasn't run yet.")
                .foregroundStyle(.secondary)
        }
    }

    /// Such as "1 failed · 2 warnings · 10 passed".
    private static func counts(failed: Int, warned: Int, passed: Int) -> String {
        var parts: [String] = []
        if failed > 0 { parts.append("\(failed.formatted()) failed") }
        if warned > 0 { parts.append(warned == 1 ? "1 warning" : "\(warned.formatted()) warnings") }
        if passed > 0 { parts.append("\(passed.formatted()) passed") }
        return parts.joined(separator: " · ")
    }

    /// Consecutive checks in the same category, in the order sbx gave them.
    private static func grouped(_ checks: [SbxDiagnostics.Check]) -> [(offset: Int, element: (category: String?, checks: [SbxDiagnostics.Check]))] {
        var groups: [(category: String?, checks: [SbxDiagnostics.Check])] = []
        for check in checks {
            if let last = groups.indices.last, groups[last].category == check.category {
                groups[last].checks.append(check)
            } else {
                groups.append((check.category, [check]))
            }
        }
        return Array(groups.enumerated())
    }
}

/// One `sbx diagnose` check: its status, name and result, with the detail and,
/// for warnings and failures, what to do.
private struct SbxDiagnosticRow: View {
    let check: SbxDiagnostics.Check

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SbxStatusIcon(status: check.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(check.name)
                        .fontWeight(.medium)
                    if !check.message.isEmpty {
                        Text(check.message)
                            .foregroundStyle(.secondary)
                    }
                }
                if !check.detail.isEmpty {
                    Text(check.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
                if !check.hint.isEmpty && (check.status == .fail || check.status == .warn) {
                    Text(check.hint)
                        .font(.callout)
                }
            }
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.name), \(check.status.accessibilityName): \(check.message)")
    }
}

/// Green for passed, orange for a warning, red for failed and grey for skipped.
private struct SbxStatusIcon: View {
    let status: SbxDiagnostics.Check.Status

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private var systemImage: String {
        switch status {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.circle.fill"
        case .skip: "minus.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        case .skip: .secondary
        }
    }
}

private extension SbxDiagnostics.Check.Status {
    var accessibilityName: String {
        switch self {
        case .pass: "passed"
        case .warn: "warning"
        case .fail: "failed"
        case .skip: "skipped"
        }
    }
}

/// A shell command in monospaced text with a button that copies it.
private struct CopyableCommand: View {
    let command: String
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                didCopy = true
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .help("Copy the command")
        }
        .padding(.leading, 10)
        .padding([.trailing, .vertical], 6)
        .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 8))
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
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
