import SwiftUI
import AppKit

/// Shown when no sandbox is selected: anything to do before sandboxes work,
/// requests waiting for approval across every sandbox, and shortcuts for
/// creating a sandbox.
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
                    // What the user needs to do comes first, without a
                    // heading. The details are in Settings › sbx.
                    let actions = sbxStatus.actions
                    if !actions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(actions) { action in
                                SbxActionCard(action: action)
                            }
                        }
                    }
                    PendingApprovalsCard(approvalResponse: $approvalResponse)
                        .id(HomeAnchor.approvals)
                    QuickCreateSection()
                    EnvironmentsSection()
                }
                .frame(maxWidth: 880, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .approvalResponseDialog($approvalResponse)
        .sheet(item: Binding(get: { sbxStatus.commandRun(in: .main) }, set: { sbxStatus.commandRun = $0 })) { run in
            SbxCommandSheet(run: run)
        }
        .task { await checkSbx() }
        // The user may install or upgrade sbx, or sign in, in their
        // terminal, so look again when they come back.
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
                    store.selection = sandbox.map { SidebarItem.sandbox($0.id) }
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

/// A card at the top of the page for something the user needs to do: install
/// or upgrade sbx, start the daemon, or sign in. It shows the command, so it
/// can be copied and run in Terminal, with a button below that runs it here
/// and shows the output.
private struct SbxActionCard: View {
    let action: SbxStatus.Action
    @Environment(SbxStatus.self) private var sbxStatus
    @Environment(SandboxStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var hasHomebrew = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                StatusDot(color: isUpgrade ? .orange : .red)
                Text(title)
                    .font(.headline)
                if let release = upgradeRelease {
                    Spacer()
                    // Hidden until a newer release comes out.
                    Button("Dismiss", systemImage: "xmark") {
                        withAnimation { sbxStatus.dismissUpgrade(to: release) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                }
            }
            Text(explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let command {
                CopyableCommand(command: command.commandLine)
                if command.usesHomebrew && !hasHomebrew {
                    Text("Homebrew isn't installed, so Sandboxes can't run this for you. Install Homebrew first, or download sbx from GitHub.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Button(buttonTitle) {
                        // Reload the sandboxes afterwards: they can't load
                        // without sbx, its daemon, or sometimes signing in.
                        sbxStatus.run(command) { [store] in
                            Task { await store.refresh() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sbxStatus.commandRun?.phase == .running)
                    .help("Run \(command.commandLine)")
                }
            }
            if isUpgrade, store.sandboxes.contains(where: { $0.state == .running }) {
                Label("Upgrading stops the sbx daemon, so your running sandboxes will stop.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // Links look like links, not buttons, so the command's button is
            // the only button on every card.
            links
                .font(.callout)
                .buttonStyle(.link)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
        .task {
            hasHomebrew = await Task.detached { Homebrew.executableURL() != nil }.value
        }
    }

    /// The command that does what the card asks, or nil when the app can't
    /// run one: sbx wasn't installed with Homebrew, so it can't upgrade it.
    private var command: SbxCommandRun.Kind? {
        switch action {
        case .install: .install
        case let .upgrade(installation, _): installation.upgrade
        case let .fix(kind, _): kind
        }
    }

    private var isUpgrade: Bool {
        upgradeRelease != nil
    }

    /// The release the card offers to upgrade to, if it's the upgrade card.
    private var upgradeRelease: SbxStatus.Release? {
        guard case let .upgrade(_, release) = action else { return nil }
        return release
    }

    private var title: String {
        switch action {
        case .install: "sbx isn't installed"
        case let .upgrade(_, release): "sbx \(release.version) is available"
        case .fix(.startDaemon, _): "The sbx daemon isn't running"
        case .fix(.signIn, _): "You aren't signed in to Docker"
        case .fix: "sbx needs attention"
        }
    }

    private var explanation: String {
        switch action {
        case .install:
            return "Sandboxes uses the Docker Sandboxes command line tool, sbx. Install it with Homebrew:"
        case let .upgrade(installation, _):
            let installed = installation.version.map { "sbx \($0)" } ?? "an older version"
            return installation.upgrade == nil
                ? "You have \(installed), which wasn't installed with Homebrew. Download the new version from GitHub."
                : "You have \(installed). Upgrade it with Homebrew:"
        case .fix(.startDaemon, _):
            return "sbx runs your sandboxes through a background daemon. Start it to list, create and run sandboxes:"
        case .fix(.signIn, _):
            return "sbx needs you signed in to Docker to create and run sandboxes. You'll get a code to enter in your browser:"
        case .fix:
            return "Run this to fix it:"
        }
    }

    private var buttonTitle: String {
        switch command {
        case .install: "Install sbx"
        case .upgrade: "Upgrade sbx"
        case .startDaemon: "Start Daemon"
        case .signIn: "Sign In…"
        case .authoriseMCP, .restartDaemon, nil: ""
        }
    }

    @ViewBuilder
    private var links: some View {
        switch action {
        case .install:
            HStack(spacing: 16) {
                if !hasHomebrew {
                    Link("Install Homebrew", destination: Homebrew.installURL)
                }
                Link("Download from GitHub", destination: SbxStatus.releasesURL)
                Button("Already installed? Set its location in Settings…") {
                    SettingsTab.show(.sbx, openSettings)
                }
            }
        case let .upgrade(installation, release):
            Link(installation.upgrade == nil ? "Download from GitHub" : "Release notes", destination: release.url)
        case .fix:
            EmptyView()
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

// MARK: - Environments

/// Cards for the most recently changed environment files, which create
/// their sandbox, and one to open a file from anywhere.
private struct EnvironmentsSection: View {
    @Environment(SandboxStore.self) private var store
    @Environment(EnvironmentStore.self) private var environments

    private static let maxCards = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HomeSectionHeader(title: "Create from an Environment File")
                Spacer()
                if !environments.environments.isEmpty {
                    Button("Show All") { store.selection = .environments }
                        .buttonStyle(.link)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(environments.environments.filter { $0.problem == nil }.prefix(Self.maxCards)) { file in
                    EnvironmentCard(file: file) {
                        environments.startCreating(from: file)
                    }
                }
                EnvironmentCard(file: nil) {
                    if EnvironmentFilePanel.open(into: environments) != nil {
                        store.selection = .environments
                    }
                }
            }
        }
        .onAppear { environments.refresh() }
    }
}

/// A card that creates the sandbox an environment file describes, or opens
/// a file when `file` is nil.
private struct EnvironmentCard: View {
    let file: EnvironmentFile?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: file == nil ? "square.and.arrow.down" : "square.stack.3d.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(file == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 40, height: 40)
                    .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(file?.displayName ?? "Open File…")
                        .font(.headline)
                        .lineLimit(1)
                    if let file {
                        Text(file.summary)
                            .font(.caption)
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
        .help(file.map { "Create a sandbox from “\($0.displayName)” after reviewing its plan" } ?? "Open an existing environment file to manage and create sandboxes from")
    }
}

// MARK: - Quick create

private struct QuickCreateSection: View {
    @Environment(SandboxStore.self) private var store
    @Environment(RecentsStore.self) private var recents
    @AppStorage(AgentVersion.key) private var agentVersion = AgentVersion.kit

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
    /// been created, the first few agents in the version picked last.
    private var workloads: [String] {
        guard !recents.workloads.isEmpty else {
            return Agent.creatable(in: agentVersion).prefix(3).compactMap { $0.workload(for: agentVersion) }
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

/// A card that opens the New Sandbox window with `workload`, or a blank card for a
/// new sandbox when it's nil.
private struct QuickCreateCard: View {
    let workload: String?
    let action: () -> Void

    @State private var isHovering = false

    static func agent(for workload: String) -> Agent? {
        Agent(workload: workload) ?? Agent(identifier: workload)
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
