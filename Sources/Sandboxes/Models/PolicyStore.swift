import Foundation
import Observation

/// What's entered in the network rule editor, to add a rule or replace one.
struct NetworkRuleDraft: Identifiable {
    enum Protocols: String, CaseIterable, Identifiable {
        /// No `--protocol`, so sbx picks: TCP for allow rules, both for deny rules.
        case automatic
        case tcp
        case udp
        case both

        var id: Self { self }

        var title: String {
            switch self {
            case .automatic: "Default"
            case .tcp: "TCP"
            case .udp: "UDP"
            case .both: "TCP and UDP"
            }
        }

        init(_ protocols: Set<NetworkRule.NetworkProtocol>) {
            switch (protocols.contains(.tcp), protocols.contains(.udp)) {
            case (true, true): self = .both
            case (true, false): self = .tcp
            case (false, true): self = .udp
            case (false, false): self = .automatic
            }
        }

        var argument: String? {
            switch self {
            case .automatic: nil
            case .tcp: "tcp"
            case .udp: "udp"
            case .both: "tcp,udp"
            }
        }
    }

    let id = UUID()
    var decision = PolicyDecision.allow
    /// Hosts, domains, IP addresses or CIDR prefixes, one per line. Commas
    /// and spaces separate them too, for a pasted list.
    var resources = ""
    /// The sandbox the rule is for, or nil for every sandbox.
    var sandbox: String?
    var protocols = Protocols.automatic
    /// The rule being edited, which saving replaces.
    private(set) var original: NetworkRule?

    init(sandbox: String? = nil) {
        self.sandbox = sandbox
    }

    init(editing rule: NetworkRule) {
        decision = rule.decision
        resources = rule.resources.joined(separator: "\n")
        sandbox = rule.sandboxName
        protocols = Protocols(rule.protocols)
        original = rule
    }

    var isEditing: Bool { original != nil }

    var resourceList: [String] {
        resources
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
    }

    /// Why the rule can't be saved yet, or nil when it can.
    var missing: String? {
        resourceList.isEmpty ? "Enter at least one host." : nil
    }

    var arguments: [String] {
        var arguments = ["policy", decision == .allow ? "allow" : "deny", "network"]
        if let sandbox {
            arguments += ["--sandbox", sandbox]
        }
        if let protocols = protocols.argument {
            arguments += ["--protocol", protocols]
        }
        return arguments + [resourceList.joined(separator: ",")]
    }
}

/// The rules of every policy, for every sandbox and for each one, in
/// Management › Policies: network rules, which can be added with
/// `sbx policy`, and file system rules, which can only be listed.
@MainActor
@Observable
final class PolicyStore {
    /// A sandbox's own rules of either kind. One of the two may be empty.
    struct SandboxRules: Identifiable {
        let sandbox: String
        let networkRules: [NetworkRule]
        let filesystemRules: [FilesystemRule]

        var id: String { sandbox }
    }

    private(set) var networkRules: [NetworkRule] = []
    private(set) var filesystemRules: [FilesystemRule] = []
    private(set) var hasLoaded = false
    private(set) var networkLoadError: String?
    private(set) var filesystemLoadError: String?
    /// Rules with a removal in flight.
    private(set) var removingIDs: Set<NetworkRule.ID> = []
    var actionError: SandboxStore.ActionError?

    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshAgain = false

    var ruleCount: Int {
        networkRules.count + filesystemRules.count
    }

    var globalNetworkRules: [NetworkRule] {
        networkRules.filter { $0.sandboxName == nil }
    }

    var globalFilesystemRules: [FilesystemRule] {
        filesystemRules.filter { $0.sandboxName == nil }
    }

    /// Each sandbox with rules of its own of either kind, by name.
    var sandboxRules: [SandboxRules] {
        let network = Dictionary(grouping: networkRules.filter { $0.sandboxName != nil }) { $0.sandboxName ?? "" }
        let filesystem = Dictionary(grouping: filesystemRules.filter { $0.sandboxName != nil }) { $0.sandboxName ?? "" }
        return Set(network.keys).union(filesystem.keys)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { SandboxRules(sandbox: $0, networkRules: network[$0] ?? [], filesystemRules: filesystem[$0] ?? []) }
    }

    /// Reloads the rules. Calls made while a reload is in flight queue one
    /// more reload, so a change just made always shows.
    func refresh() async {
        if isRefreshing {
            refreshAgain = true
            return
        }
        isRefreshing = true
        repeat {
            refreshAgain = false
            await load()
        } while refreshAgain
        isRefreshing = false
    }

    /// Each kind reports its own failure, so one that fails doesn't hide the other.
    private func load() async {
        async let latestNetwork = Self.fetchNetworkRules()
        async let latestFilesystem = Self.fetchFilesystemRules()
        do {
            let latest = try await latestNetwork
            if latest != networkRules {
                networkRules = latest
            }
            networkLoadError = nil
        } catch {
            networkLoadError = error.localizedDescription
        }
        do {
            let latest = try await latestFilesystem
            if latest != filesystemRules {
                filesystemRules = latest
            }
            filesystemLoadError = nil
        } catch {
            filesystemLoadError = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Every policy's network rules, including those scoped to a sandbox.
    nonisolated private static func fetchNetworkRules() async throws -> [NetworkRule] {
        PolicyParser.rules(in: try PolicyParser.document(
            try await SbxCLI.runChecked(["policy", "ls", "--type", "network", "--json"])
        ))
    }

    /// Every policy's file system rules, including those scoped to a sandbox.
    nonisolated private static func fetchFilesystemRules() async throws -> [FilesystemRule] {
        PolicyParser.filesystemRules(in: try PolicyParser.document(
            try await SbxCLI.runChecked(["policy", "ls", "--type", "filesystem", "--json"])
        ))
    }

    /// Adds the rule. sbx can't change a rule, so editing one removes it and
    /// adds the new one, putting the old one back if that fails.
    func save(_ draft: NetworkRuleDraft) async throws {
        if let original = draft.original, let removeArguments = original.removeArguments {
            try await SbxCLI.runChecked(removeArguments)
            do {
                try await SbxCLI.runChecked(draft.arguments)
            } catch {
                try? await SbxCLI.runChecked(NetworkRuleDraft(editing: original).arguments)
                await refresh()
                throw error
            }
        } else {
            try await SbxCLI.runChecked(draft.arguments)
        }
        await refresh()
    }

    func remove(_ rule: NetworkRule) async {
        guard let arguments = rule.removeArguments else { return }
        removingIDs.insert(rule.id)
        defer { removingIDs.remove(rule.id) }
        do {
            try await SbxCLI.runChecked(arguments)
        } catch {
            actionError = SandboxStore.ActionError(
                title: "Couldn't Remove the Rule for “\(rule.resources.joined(separator: ", "))”",
                message: error.localizedDescription
            )
        }
        await refresh()
    }

    func isRemoving(_ rule: NetworkRule) -> Bool {
        removingIDs.contains(rule.id)
    }
}
