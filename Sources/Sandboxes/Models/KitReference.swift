import Foundation

/// Where a kit comes from. sbx accepts all three wherever it takes a kit
/// (https://docs.docker.com/ai/sandboxes/customize/use-kits/#choose-a-kit-source).
enum KitSource: String, CaseIterable, Identifiable {
    case registry
    case git
    case local

    var id: Self { self }

    var title: String {
        switch self {
        case .registry: "Registry"
        case .git: "Git"
        case .local: "Local"
        }
    }

    var systemImage: String {
        switch self {
        case .registry: "shippingbox"
        case .git: "arrow.triangle.branch"
        case .local: "folder"
        }
    }

    /// The source a kit reference points at, going by how sbx tells them apart.
    init(reference: String) {
        let reference = reference.lowercased()
        if reference.hasPrefix("git+") {
            self = .git
        } else if reference.hasPrefix("/") || reference.hasPrefix("./") || reference.hasPrefix("../")
                    || reference.hasPrefix("~") || reference.hasSuffix(".zip") {
            self = .local
        } else {
            self = .registry
        }
    }
}

/// A kit in a Git repository, as typed into the create sheet. The repository
/// can be a plain clone URL, a full `git+…#ref=…&dir=…` reference, or a GitHub
/// or GitLab page for a folder; `reference` turns any of them into what sbx
/// expects.
struct GitKitDraft: Equatable {
    var repository = ""
    var ref = ""
    var folder = ""

    var isEmpty: Bool {
        repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `git+URL#ref=REF&dir=FOLDER`, or nil if the repository isn't a URL.
    var reference: String? {
        var text = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("git+") {
            text = String(text.dropFirst(4))
        }

        // Anything after # is ref and dir parameters from a pasted reference.
        var parameters: [String: String] = [:]
        if let hash = text.firstIndex(of: "#") {
            for pair in text[text.index(after: hash)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { parameters[parts[0]] = parts[1] }
            }
            text = String(text[..<hash])
        }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else {
            return nil
        }
        if let page = Self.repositoryPage(components) {
            components.path = page.path
            parameters["ref"] = parameters["ref"] ?? page.ref
            if let folder = page.folder { parameters["dir"] = parameters["dir"] ?? folder }
        }
        components.query = nil
        components.fragment = nil
        guard let url = components.string else { return nil }

        // Fields typed separately win over anything in the pasted URL.
        let ref = trimmed(ref) ?? parameters["ref"]
        let folder = trimmed(folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ?? parameters["dir"]
        let fragment = [ref.map { "ref=\($0)" }, folder.map { "dir=\($0)" }].compactMap { $0 }
        return "git+" + url + (fragment.isEmpty ? "" : "#" + fragment.joined(separator: "&"))
    }

    private func trimmed(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Splits a GitHub (`/org/repo/tree/REF/FOLDER`) or GitLab
    /// (`/group/repo/-/tree/REF/FOLDER`) page URL into the repository's clone
    /// path, ref and folder. A ref containing a slash can't be told apart from
    /// the folder, so it's taken to be the first component.
    private static func repositoryPage(_ components: URLComponents) -> (path: String, ref: String, folder: String?)? {
        var parts = components.path.split(separator: "/").map(String.init)
        guard let marker = parts.firstIndex(where: { $0 == "tree" || $0 == "blob" }),
              marker >= 2, marker + 1 < parts.count
        else { return nil }
        let ref = parts[marker + 1]
        let folder = parts[(marker + 2)...].joined(separator: "/")
        parts = Array(parts[..<marker])
        if parts.last == "-" { parts.removeLast() }
        var path = "/" + parts.joined(separator: "/")
        if !path.hasSuffix(".git") { path += ".git" }
        return (path, ref, folder.isEmpty ? nil : folder)
    }
}
