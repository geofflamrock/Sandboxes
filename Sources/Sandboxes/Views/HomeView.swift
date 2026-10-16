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
        .sheet(item: Binding(get: { sbxStatus.commandRun }, set: { sbxStatus.commandRun = $0 })) { run in
            SbxCommandSheet(run: run)
        }
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
/// to install or upgrade it. The user runs the command themselves. Laid out
/// as rows like a grouped form, with the checks folding away like the
/// sections of the create sheet.
private struct SbxStatusSection: View {
    @Environment(SbxStatus.self) private var sbxStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeader(title: "Setup", isLoading: sbxStatus.isDiagnosing)

            // Things to fix before sandboxes work get their own cards first,
            // like sbx not being installed.
            ForEach(sbxStatus.fixes) { fix in
                SbxFixCard(fix: fix)
            }

            VStack(alignment: .leading, spacing: 0) {
                switch sbxStatus.state {
                case .checking:
                    SbxRow {
                        Text("Looking for sbx…")
                            .foregroundStyle(.secondary)
                    }
                case .notInstalled:
                    SbxNotInstalledRow()
                case let .installed(installation):
                    SbxVersionRow(installation: installation)
                    if let upgrade = sbxStatus.availableUpgrade {
                        SbxRowDivider()
                        SbxUpgradeRow(installation: installation, upgrade: upgrade)
                    }
                    SbxRowDivider()
                    SbxDiagnosticsRows()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CardBackground())
        }
    }
}

/// A row of the sbx card, padded like the pending approvals.
private struct SbxRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
}

private struct SbxRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 14)
    }
}

/// A name with an optional detail line underneath, and a status dot and
/// value on the right.
private struct SbxValueRow<Title: View>: View {
    var detail: String = ""
    let color: Color
    let value: String
    @ViewBuilder let title: Title

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                title
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                StatusDot(color: color)
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
        }
    }
}

private struct SbxNotInstalledRow: View {
    var body: some View {
        SbxRow {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    StatusDot(color: .red)
                    Text("sbx isn't installed")
                        .font(.headline)
                }
                Text("Sandboxes uses the Docker Sandboxes command line tool, sbx. Install it with Homebrew by running this in Terminal:")
                    .foregroundStyle(.secondary)
                CopyableCommand(command: SbxStatus.installCommand)
                HStack(spacing: 16) {
                    Link("Download from GitHub", destination: SbxStatus.releasesURL)
                    SettingsLink { Text("Already installed? Set its location in Settings…") }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
        }
    }
}

/// A card for something to fix before sandboxes work, found by
/// `sbx diagnose`: the daemon isn't running, or the user isn't signed in.
private struct SbxFixCard: View {
    let fix: SbxStatus.Fix
    @Environment(SbxStatus.self) private var sbxStatus
    @Environment(SandboxStore.self) private var store

    var body: some View {
        SbxRow {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    StatusDot(color: .red)
                    Text(title)
                        .font(.headline)
                }
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !fix.check.hint.isEmpty {
                    Text(fix.check.hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button(buttonTitle) {
                    // Reload the sandboxes afterwards: they can't load
                    // without the daemon, or sometimes without signing in.
                    sbxStatus.run(fix.kind) { [store] in
                        Task { await store.refresh() }
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(sbxStatus.commandRun?.phase == .running)
                .help(help)
            }
        }
        .modifier(CardBackground())
    }

    private var title: String {
        switch fix.kind {
        case .startDaemon: "The sbx daemon isn't running"
        case .signIn: "You aren't signed in to Docker"
        }
    }

    private var explanation: String {
        switch fix.kind {
        case .startDaemon:
            "sbx runs your sandboxes through a background daemon. Start it to list, create and run sandboxes."
        case .signIn:
            "sbx needs you signed in to Docker to create and run sandboxes. You'll get a code to enter in your browser."
        }
    }

    private var buttonTitle: String {
        switch fix.kind {
        case .startDaemon: "Start Daemon"
        case .signIn: "Sign In…"
        }
    }

    private var help: String {
        switch fix.kind {
        case .startDaemon: "Run sbx daemon start --detach"
        case .signIn: "Sign in to Docker with sbx login"
        }
    }
}

private struct SbxVersionRow: View {
    let installation: SbxStatus.Installation
    @Environment(SbxStatus.self) private var sbxStatus

    var body: some View {
        SbxRow {
            SbxValueRow(detail: installation.path, color: status.color, value: status.text) {
                Text(installation.version.map { "sbx \($0)" } ?? "sbx")
                    .font(.headline)
            }
        }
    }

    private var status: (color: Color, text: String) {
        if let upgrade = sbxStatus.availableUpgrade {
            return (.orange, "\(upgrade.version) available")
        }
        if installation.version == nil {
            return (.orange, "Unknown version")
        }
        return sbxStatus.latest == nil ? (.green, "Installed") : (.green, "Up to date")
    }
}

/// The command to upgrade sbx, or where to download it.
private struct SbxUpgradeRow: View {
    let installation: SbxStatus.Installation
    let upgrade: SbxStatus.Release
    @Environment(SandboxStore.self) private var store

    var body: some View {
        SbxRow {
            VStack(alignment: .leading, spacing: 10) {
                if let command = installation.upgradeCommand {
                    Text("Upgrade to sbx \(upgrade.version) by running this in Terminal:")
                        .foregroundStyle(.secondary)
                    CopyableCommand(command: command)
                } else {
                    Text("This sbx wasn't installed with Homebrew. Download sbx \(upgrade.version) from GitHub.")
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
    }
}

/// A row that folds the `sbx diagnose` checks away, like the sections of the
/// create sheet. It opens by itself when a check fails or warns.
private struct SbxDiagnosticsRows: View {
    @Environment(SbxStatus.self) private var sbxStatus
    @AppStorage("homeShowsDiagnostics") private var isExpanded = false

    var body: some View {
        SbxRow {
            // The toggle and Run Again are separate buttons, so the toggle
            // stops short of Run Again; the summary toggles too.
            HStack(spacing: 10) {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12)
                        Text("Diagnostics")
                            .fontWeight(.semibold)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed, \(summaryText)")

                Button("Run Again") {
                    Task { await sbxStatus.diagnose() }
                }
                .controlSize(.small)
                .disabled(sbxStatus.isDiagnosing)
                .help("Run sbx diagnose again")

                if !isExpanded {
                    summary
                        .contentShape(.rect)
                        .onTapGesture(perform: toggle)
                        .accessibilityHidden(true)
                }
            }
        }
        .onChange(of: attentionCount, initial: true) { _, count in
            if count > 0 { isExpanded = true }
        }

        if isExpanded {
            if let diagnostics = sbxStatus.diagnostics {
                ForEach(diagnostics.checks) { check in
                    SbxRowDivider()
                    SbxDiagnosticRow(check: check)
                }
            } else if let error = sbxStatus.diagnosticsError {
                SbxRowDivider()
                SbxRow {
                    SbxValueRow(detail: error, color: .red, value: "Failed") {
                        Text("sbx diagnose")
                    }
                }
            }
        }
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
    }

    private var attentionCount: Int {
        sbxStatus.diagnostics.map { $0.count(.fail) + $0.count(.warn) } ?? 0
    }

    @ViewBuilder
    private var summary: some View {
        if sbxStatus.diagnostics == nil && sbxStatus.diagnosticsError == nil {
            Text(summaryText)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                StatusDot(color: summaryColor)
                Text(summaryText)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summaryColor: Color {
        guard let diagnostics = sbxStatus.diagnostics else { return .red }
        if diagnostics.count(.fail) > 0 { return .red }
        if diagnostics.count(.warn) > 0 { return .orange }
        return .green
    }

    /// Such as "All 14 passed" or "1 failed · 2 warnings · 10 passed".
    private var summaryText: String {
        guard let diagnostics = sbxStatus.diagnostics else {
            if sbxStatus.diagnosticsError != nil { return "Couldn't run" }
            return sbxStatus.isDiagnosing ? "Running…" : "Not run yet"
        }
        let failed = diagnostics.count(.fail)
        let warned = diagnostics.count(.warn)
        let passed = diagnostics.count(.pass)
        if failed == 0 && warned == 0 && passed == diagnostics.checks.count {
            return "All \(passed.formatted()) passed"
        }
        var parts: [String] = []
        if failed > 0 { parts.append("\(failed.formatted()) failed") }
        if warned > 0 { parts.append(warned == 1 ? "1 warning" : "\(warned.formatted()) warnings") }
        if passed > 0 { parts.append("\(passed.formatted()) passed") }
        let skipped = diagnostics.count(.skip)
        if skipped > 0 { parts.append("\(skipped.formatted()) skipped") }
        return parts.joined(separator: " · ")
    }
}

/// One `sbx diagnose` check: its name and detail on the left, and its status
/// and result on the right. Warnings and failures also say what to do.
private struct SbxDiagnosticRow: View {
    let check: SbxDiagnostics.Check

    var body: some View {
        SbxRow {
            VStack(alignment: .leading, spacing: 4) {
                SbxValueRow(
                    detail: check.detail,
                    color: color,
                    value: check.message.isEmpty ? check.status.displayName : check.message
                ) {
                    Text(check.name)
                }
                if !check.hint.isEmpty && (check.status == .fail || check.status == .warn) {
                    Text(check.hint)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
    }


    /// Green for passed, orange for a warning, red for failed and grey for
    /// skipped.
    private var color: Color {
        switch check.status {
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        case .skip: .secondary
        }
    }
}

private extension SbxDiagnostics.Check.Status {
    var displayName: String {
        switch self {
        case .pass: "Passed"
        case .warn: "Warning"
        case .fail: "Failed"
        case .skip: "Skipped"
        }
    }
}

/// A shell command in monospaced text with a button that copies it.
struct CopyableCommand: View {
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
