import Foundation
import Observation

/// Searches Docker Hub for kits as text is typed in the New Sandbox window.
/// Results are kept while the window is open, so going back to a search
/// doesn't fetch it again.
@MainActor
@Observable
final class KitSearchModel {
    struct Query: Hashable {
        var text: String
        var filter: KitSearch.Filter
    }

    private(set) var results: [KitSearchResult] = []
    private(set) var isSearching = false
    private(set) var error: String?
    /// The search `results` are for.
    private(set) var shownQuery: Query?

    @ObservationIgnored private var cache: [Query: [KitSearchResult]] = [:]

    /// Searches once typing pauses. Call it from `.task(id:)`, which cancels
    /// the search when the query changes. Earlier results stay until new
    /// ones arrive, so the list doesn't empty with each key pressed.
    func search(_ query: Query) async {
        let query = Query(text: KitSearch.searchText(for: query.text), filter: query.filter)
        // A search cancelled while it was running leaves this set.
        isSearching = false
        if let cached = cache[query] {
            show(cached, for: query)
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { if !Task.isCancelled { isSearching = false } }
        do {
            let found = try await KitSearch.search(query.text, filter: query.filter)
            guard !Task.isCancelled else { return }
            cache[query] = found
            show(found, for: query)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func show(_ found: [KitSearchResult], for query: Query) {
        results = found
        shownQuery = query
        error = nil
        isSearching = false
    }
}
