import SwiftUI

/// Kits on Docker Hub matching what's typed in the New Sandbox window, for
/// the agent or for mixins, with filters for who published them. Clicking a
/// kit picks it.
struct KitSearchSection: View {
    let query: String
    let kind: KitSearchResult.Kind
    let model: KitSearchModel
    /// Kits already picked, which show as added rather than being picked twice.
    let picked: [String]
    let onPick: (String) -> Void

    @AppStorage(KitSearch.verifiedPublishersKey) private var verifiedPublishers = true
    @AppStorage(KitSearch.hardenedImagesKey) private var hardenedImages = true
    @State private var showsAll = false

    private static let shownLimit = 8

    private var filter: KitSearch.Filter {
        KitSearch.Filter(verifiedPublishers: verifiedPublishers, hardenedImages: hardenedImages)
    }

    private var results: [KitSearchResult] {
        model.results.filter { $0.fits(kind) }
    }

    private var pickedRepositories: Set<String> {
        Set(picked.map(KitSearch.searchText(for:)))
    }

    var body: some View {
        Section {
            let results = results
            let shown = showsAll ? results : Array(results.prefix(Self.shownLimit))
            ForEach(shown) { result in
                KitSearchRow(result: result, isPicked: pickedRepositories.contains(result.reference)) {
                    onPick(result.reference)
                }
            }
            if results.count > shown.count {
                Button("Show All \(results.count) Kits") { showsAll = true }
                    .buttonStyle(.borderless)
            }
            if results.isEmpty {
                status
            }
        } header: {
            HStack {
                Text("Docker Hub")
                if model.isSearching {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                Toggle("Verified publishers", isOn: $verifiedPublishers)
                    .help("Show kits from publishers Docker Hub has verified, such as Docker.")
                Toggle("Docker Hardened Images", isOn: $hardenedImages)
                    .help("Show Docker Hardened Images.")
            }
            .toggleStyle(.button)
            .controlSize(.small)
        } footer: {
            if let footer {
                Text(footer)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: KitSearchModel.Query(text: query, filter: filter)) {
            showsAll = false
            await model.search(KitSearchModel.Query(text: query, filter: filter))
        }
    }

    @ViewBuilder
    private var status: some View {
        if let error = model.error {
            Label {
                Text(error)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else if model.isSearching || model.shownQuery == nil {
            Text("Searching Docker Hub…")
                .foregroundStyle(.secondary)
        } else {
            let text = KitSearch.searchText(for: query)
            Text(text.isEmpty ? "No kits found." : "No kits match “\(text)”.")
                .foregroundStyle(.secondary)
        }
    }

    private var footer: String? {
        if model.error != nil {
            return "You can still enter a kit's full reference."
        }
        if !verifiedPublishers && !hardenedImages {
            return "Showing kits from all publishers. Check what a community kit does before using it."
        }
        return nil
    }
}

/// A kit found on Docker Hub: its logo, name and description, and who
/// published it.
private struct KitSearchRow: View {
    let result: KitSearchResult
    let isPicked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                KitLogo(result: result)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(result.title)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(result.reference)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let summary = result.summary {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    publisher
                }
                Spacer(minLength: 8)
                if isPicked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .help("Added")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isPicked)
        .help(isPicked ? "“\(result.reference)” is added" : "Add “\(result.reference)”")
    }

    private var publisher: some View {
        HStack(spacing: 6) {
            switch result.badge {
            case .verifiedPublisher:
                Label(result.publisherName, systemImage: "checkmark.seal.fill")
                    .help("Docker Hub has verified this publisher")
            case .hardened:
                Label(result.publisherName, systemImage: "checkmark.shield.fill")
                KitChip(text: "Hardened", color: .green)
            case .none:
                Text(result.publisherName)
                KitChip(text: "Unverified publisher", color: .orange)
            }
            if let pulls = result.pullCount, pulls > 0 {
                Text("·")
                Text("\(pulls.formatted(.number.notation(.compactName))) pulls")
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// The kit's logo from Docker Hub, or its agent's logo or a box when it has
/// none. It keeps its size while loading so rows don't move.
private struct KitLogo: View {
    let result: KitSearchResult
    private let size: CGFloat = 28

    var body: some View {
        Group {
            if let url = result.logoURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 6))
    }

    private var placeholder: some View {
        let agent = Agent(workload: result.reference)
        return AgentIcon(agent: agent, size: size - 6, filled: true)
            .foregroundStyle(agent?.color ?? Color.secondary)
            .frame(width: size, height: size)
    }
}

private struct KitChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: .capsule)
    }
}
