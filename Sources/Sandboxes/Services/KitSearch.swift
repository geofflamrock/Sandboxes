import Foundation

/// Searches Docker Hub for kits. sbx has no search command, so this calls
/// the search API behind hub.docker.com, which needs no sign-in.
enum KitSearch {
    /// Which publishers to search. With neither, every publisher's kits are
    /// searched, community ones included.
    struct Filter: Hashable {
        var verifiedPublishers: Bool
        var hardenedImages: Bool

        /// Docker Hub's `badges` parameter. Several badges are joined with
        /// commas: repeating the parameter only applies the first.
        var badges: String? {
            let badges = [verifiedPublishers ? "verified_publisher" : nil, hardenedImages ? "hardened" : nil]
                .compactMap { $0 }
            return badges.isEmpty ? nil : badges.joined(separator: ",")
        }
    }

    static let verifiedPublishersKey = "kitSearchVerifiedPublishers"
    static let hardenedImagesKey = "kitSearchHardenedImages"

    /// Docker Hub returns at most 100 results for a search without signing in.
    private static let pageSize = 100

    struct HTTPError: LocalizedError {
        let status: Int
        var errorDescription: String? {
            "Docker Hub couldn't search for kits (HTTP \(status))."
        }
    }

    static func url(query: String, filter: Filter) -> URL? {
        var components = URLComponents(string: "https://hub.docker.com/api/search/v4")
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "type", value: "sbx_kit"),
            URLQueryItem(name: "size", value: String(pageSize)),
        ]
        if let badges = filter.badges {
            items.append(URLQueryItem(name: "badges", value: badges))
        }
        components?.queryItems = items
        return components?.url
    }

    /// v3 kits matching `query`, Docker's first. A full reference, such as
    /// `docker.io/sbx/mise:latest`, searches for its repository.
    static func search(_ query: String, filter: Filter) async throws -> [KitSearchResult] {
        guard let url = url(query: searchText(for: query), filter: filter) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw HTTPError(status: status)
        }
        return KitSearchResult.ordered(try KitSearchParser.parse(data))
    }

    /// What to send for `query`: without a registry, tag or digest, which
    /// Docker Hub's search doesn't match.
    static func searchText(for query: String) -> String {
        var text = Substring(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        for prefix in ["https://", "docker.io/", "index.docker.io/", "hub.docker.com/r/"] where text.hasPrefix(prefix) {
            text = text.dropFirst(prefix.count)
        }
        if let at = text.firstIndex(of: "@") { text = text[..<at] }
        if let colon = text.lastIndex(of: ":"), !text[colon...].contains("/") { text = text[..<colon] }
        return String(text)
    }
}
