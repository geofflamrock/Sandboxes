import Foundation

/// A kit found by searching Docker Hub, as the New Sandbox window lists it.
struct KitSearchResult: Hashable, Identifiable {
    /// Docker Hub's mark for who published the kit.
    enum Badge: Hashable {
        case verifiedPublisher
        /// Docker Hardened Images, published as `dhi/…`.
        case hardened
        case none
    }

    /// What a kit is for, from its descriptor's `kind`.
    enum Kind: Hashable {
        /// An agent, picked as the sandbox's workload.
        case workload
        /// Adds tools and settings to the agent.
        case mixin
    }

    /// `namespace/name`, which sbx pulls from Docker Hub.
    let reference: String
    var displayName: String?
    var summary: String?
    var publisher: String?
    var badge: Badge = .none
    /// Empty when Docker Hub doesn't say, as for most Docker Hardened Images.
    var kinds: Set<Kind> = []
    var pullCount: Int?
    var logoURL: URL?

    var id: String { reference }

    var namespace: String {
        reference.split(separator: "/").first.map(String.init) ?? reference
    }

    var title: String {
        displayName ?? reference.split(separator: "/").last.map(String.init) ?? reference
    }

    /// Who published it, as Docker Hub shows it.
    var publisherName: String {
        badge == .hardened ? "Docker Hardened Image" : publisher ?? namespace
    }

    /// Whether the kit belongs with workloads or mixins. One Docker Hub
    /// doesn't give a kind for fits both, until inspecting it says which.
    func fits(_ kind: Kind) -> Bool {
        kinds.isEmpty || kinds.contains(kind)
    }

    /// Docker's own kits come first, then hardened ones, then other verified
    /// publishers, then everyone else, each by how often they're pulled.
    static func ordered(_ results: [KitSearchResult]) -> [KitSearchResult] {
        func rank(_ result: KitSearchResult) -> Int {
            switch result.badge {
            case .verifiedPublisher: ["sbx", "docker"].contains(result.namespace) ? 0 : 2
            case .hardened: 1
            case .none: 3
            }
        }
        return results.enumerated().sorted { lhs, rhs in
            let (left, right) = (rank(lhs.element), rank(rhs.element))
            if left != right { return left < right }
            let (leftPulls, rightPulls) = (lhs.element.pullCount ?? 0, rhs.element.pullCount ?? 0)
            if leftPulls != rightPulls { return leftPulls > rightPulls }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

/// Reads Docker Hub's search results (`/api/search/v4`). The API isn't
/// documented, so this accepts a few spellings and skips what it can't read
/// rather than failing. Only v3 kits are kept: earlier kits have all been
/// republished as v3, often under a new name.
enum KitSearchParser {
    struct ParseError: LocalizedError {
        var errorDescription: String? { "Docker Hub's search results couldn't be read." }
    }

    private static let v3MediaType = "application/vnd.docker.sandbox.kit.v3"

    static func parse(_ data: Data) throws -> [KitSearchResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw ParseError() }
        let items: [Any]
        if let list = json as? [Any] {
            items = list
        } else if let record = json as? [String: Any],
                  let list = (record["results"] ?? record["summaries"]) as? [Any] {
            items = list
        } else {
            throw ParseError()
        }
        var seen: Set<String> = []
        return items.compactMap { item in
            guard let record = item as? [String: Any], let result = result(from: record),
                  seen.insert(result.reference).inserted
            else { return nil }
            return result
        }
    }

    private static func result(from record: [String: Any]) -> KitSearchResult? {
        let mediaTypes = strings(record["media_types"] ?? record["mediaTypes"])
        guard mediaTypes.contains(where: { $0.lowercased().hasPrefix(v3MediaType) }) else { return nil }
        let contentTypes = strings(record["content_types"] ?? record["contentTypes"])
        guard contentTypes.isEmpty || contentTypes.contains("sbx_kit") else { return nil }
        guard let reference = [record["id"], record["slug"], record["name"]]
            .compactMap({ ($0 as? String)?.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.contains("/") })
        else { return nil }

        let metadata = record["additional_metadata"] as? [String: Any] ?? [:]
        var result = KitSearchResult(reference: reference)
        result.displayName = strings(metadata["names"]).first { !$0.isEmpty }
        result.summary = (record["short_description"] as? String).flatMap(nonEmpty)
        result.publisher = ((record["publisher"] as? [String: Any])?["name"] as? String).flatMap(nonEmpty)
        switch (record["badge"] as? String ?? "").lowercased() {
        case "verified_publisher": result.badge = .verifiedPublisher
        case "hardened": result.badge = .hardened
        default: result.badge = .none
        }
        result.kinds = Set(strings(metadata["kinds"]).compactMap { (kind: String) -> KitSearchResult.Kind? in
            switch kind.lowercased() {
            case "workload": .workload
            case "mixin": .mixin
            default: nil
            }
        })
        result.pullCount = (record["raw_pull_count"] as? NSNumber)?.intValue
        result.logoURL = logoURL(record["logo_url"])
        return result
    }

    /// The repository's logo. A Gravatar is the publisher's account picture,
    /// the same for every kit it publishes, so it's not used.
    private static func logoURL(_ value: Any?) -> URL? {
        let record = value as? [String: Any]
        guard let text = (record?["small"] ?? record?["large"] ?? value) as? String,
              let url = URL(string: text), url.scheme == "https",
              url.host?.lowercased().contains("gravatar") != true
        else { return nil }
        return url
    }

    private static func strings(_ value: Any?) -> [String] {
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        if let text = value as? String { return [text] }
        return []
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
