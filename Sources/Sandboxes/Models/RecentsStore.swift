import Foundation
import Observation

/// A host mount used before: a sandbox path and the folder on the Mac.
struct RecentHostMount: Hashable, Identifiable {
    let sandboxPath: String
    let hostPath: String

    var id: Self { self }
}

/// Workload and kit images, and host mounts, used before, most recent first.
@MainActor
@Observable
final class RecentsStore {
    private static let workloadsKey = "recentWorkloads"
    private static let kitsKey = "recentKits"
    private static let hostMountsKey = "recentHostMounts"
    private static let limit = 15

    private(set) var workloads: [String]
    private(set) var kits: [String]
    private(set) var hostMounts: [RecentHostMount]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workloads = defaults.stringArray(forKey: Self.workloadsKey) ?? []
        kits = defaults.stringArray(forKey: Self.kitsKey) ?? []
        hostMounts = (defaults.array(forKey: Self.hostMountsKey) as? [[String: String]] ?? []).compactMap { record in
            guard let sandboxPath = record["sandboxPath"], let hostPath = record["hostPath"] else { return nil }
            return RecentHostMount(sandboxPath: sandboxPath, hostPath: hostPath)
        }
    }

    func record(workload: String, kits usedKits: [String], hostMounts usedHostMounts: [RecentHostMount]) {
        workloads = Self.promote([workload], in: workloads)
        kits = Self.promote(usedKits, in: kits)
        hostMounts = Self.promote(usedHostMounts, in: hostMounts)
        save()
    }

    func clearWorkloads() {
        workloads = []
        save()
    }

    func clearKits() {
        kits = []
        save()
    }

    func clearHostMounts() {
        hostMounts = []
        save()
    }

    private func save() {
        defaults.set(workloads, forKey: Self.workloadsKey)
        defaults.set(kits, forKey: Self.kitsKey)
        defaults.set(hostMounts.map { ["sandboxPath": $0.sandboxPath, "hostPath": $0.hostPath] }, forKey: Self.hostMountsKey)
    }

    private static func promote<Item: Equatable>(_ items: [Item], in list: [Item]) -> [Item] {
        var result = list.filter { !items.contains($0) }
        result.insert(contentsOf: items, at: 0)
        return Array(result.prefix(limit))
    }
}
