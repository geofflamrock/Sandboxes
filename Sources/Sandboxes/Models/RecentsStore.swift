import Foundation
import Observation

/// Workload and kit images used before, most recent first.
@MainActor
@Observable
final class RecentsStore {
    private static let workloadsKey = "recentWorkloads"
    private static let kitsKey = "recentKits"
    private static let limit = 15

    private(set) var workloads: [String]
    private(set) var kits: [String]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workloads = defaults.stringArray(forKey: Self.workloadsKey) ?? []
        kits = defaults.stringArray(forKey: Self.kitsKey) ?? []
    }

    func record(workload: String, kits usedKits: [String]) {
        workloads = Self.promote([workload], in: workloads)
        kits = Self.promote(usedKits, in: kits)
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

    private func save() {
        defaults.set(workloads, forKey: Self.workloadsKey)
        defaults.set(kits, forKey: Self.kitsKey)
    }

    private static func promote(_ items: [String], in list: [String]) -> [String] {
        var result = list.filter { !items.contains($0) }
        result.insert(contentsOf: items, at: 0)
        return Array(result.prefix(limit))
    }
}
