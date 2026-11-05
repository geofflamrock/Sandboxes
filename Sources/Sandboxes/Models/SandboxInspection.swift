import Foundation

/// What the Configuration tab shows from `sbx inspect NAME --json`.
struct SandboxInspection {
    let hostMounts: [SandboxHostMount]
    /// Nil when sbx doesn't report kits, which it does from v0.51.0.
    let kits: [SandboxKit]?

    static func fetch(for sandbox: String) async throws -> SandboxInspection {
        parse(try await SbxCLI.runChecked(["inspect", sandbox, "--json"]))
    }

    static func parse(_ output: String) -> SandboxInspection {
        guard let record = document(in: output) as? [String: Any] else {
            return SandboxInspection(hostMounts: [], kits: nil)
        }
        return SandboxInspection(hostMounts: SandboxHostMount.parse(record), kits: SandboxKit.parse(record))
    }

    /// The JSON document in `text`, skipping any warnings printed before it.
    private static func document(in text: String) -> Any? {
        var start = text.startIndex
        while let index = text[start...].firstIndex(where: { $0 == "[" || $0 == "{" }) {
            if let data = String(text[index...]).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                return json
            }
            start = text.index(after: index)
        }
        return nil
    }
}

/// A kit a sandbox was created with, as `sbx inspect` lists it: the agent's
/// kit or a mixin, as the reference sbx resolved.
struct SandboxKit: Identifiable, Hashable {
    let reference: String

    var id: String { reference }
    var source: KitSource { KitSource(reference: reference) }

    /// A short name: the image's repository for a registry kit, the folder
    /// for a Git or local kit.
    var name: String { parts.name }

    /// Where the kit comes from, beyond its name: the registry and tag or
    /// digest, the repository and ref, or the path on the Mac.
    var detail: String? { parts.detail }

    /// Whether this is the kit that provides `agent`, the agent name `sbx`
    /// reports for the sandbox, such as `docker.io/sbx/claude@sha256:…` for `claude`.
    func provides(agent: String) -> Bool {
        let agent = agent.lowercased()
        return reference.lowercased() == agent
            || name.lowercased() == agent
            || name.split(separator: "/").last.map { $0.lowercased() == agent } == true
    }

    /// The `kits` in `sbx inspect --json` output, which is a list of
    /// references in v0.51.0. Records with a reference field are accepted
    /// too, in case a later version adds more about each kit. The order sbx
    /// gives is kept.
    static func parse(_ record: [String: Any]) -> [SandboxKit]? {
        guard let list = SandboxListParser.value(in: record, for: ["kits", "kit_refs", "kitRefs"]) as? [Any] else {
            return nil
        }
        var kits: [SandboxKit] = []
        for item in list {
            let reference: String?
            if let item = item as? [String: Any] {
                reference = SandboxListParser.string(SandboxListParser.value(in: item, for: ["reference", "ref", "kit", "source", "name"]))
            } else {
                reference = SandboxListParser.string(item)
            }
            guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty,
                  !kits.contains(where: { $0.reference == reference })
            else { continue }
            kits.append(SandboxKit(reference: reference))
        }
        return kits
    }

    private var parts: (name: String, detail: String?) {
        switch source {
        case .git: gitParts
        case .local: localParts
        case .registry: registryParts
        }
    }

    /// `git+https://github.com/org/repo#ref=REF&dir=kits/node` is named
    /// `node`, from `org/repo · REF`.
    private var gitParts: (name: String, detail: String?) {
        var text = String(reference.dropFirst(4))
        var parameters: [String: String] = [:]
        if let hash = text.firstIndex(of: "#") {
            for pair in text[text.index(after: hash)...].split(separator: "&") {
                let pair = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { parameters[pair[0]] = pair[1].removingPercentEncoding ?? pair[1] }
            }
            text = String(text[..<hash])
        }
        var repository = URLComponents(string: text)?.path ?? text
        repository = repository.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if repository.hasSuffix(".git") { repository = String(repository.dropLast(4)) }
        if repository.isEmpty { repository = text }

        let folder = parameters["dir"]?.split(separator: "/").last.map(String.init)
        let name = folder ?? repository.split(separator: "/").last.map(String.init) ?? repository
        let detail = [repository, parameters["ref"]].compactMap { $0 }.joined(separator: " · ")
        return (name, detail)
    }

    /// A folder or ZIP file on the Mac is named after its last component.
    private var localParts: (name: String, detail: String?) {
        let path = (reference as NSString).expandingTildeInPath
        var name = (path as NSString).lastPathComponent
        if name.lowercased().hasSuffix(".zip") { name = (name as NSString).deletingPathExtension }
        return (name.isEmpty ? reference : name, (path as NSString).abbreviatingWithTildeInPath)
    }

    /// `docker.io/sbx/claude@sha256:8c48…` is named `sbx/claude`, from
    /// `docker.io · sha256:8c48745e7c02`. A reference without a registry,
    /// such as `sbx/playwright`, has no detail unless it has a tag.
    private var registryParts: (name: String, detail: String?) {
        var repository = reference
        var version: String?
        if let at = repository.firstIndex(of: "@") {
            let digest = String(repository[repository.index(after: at)...])
            version = digest.hasPrefix("sha256:") ? String(digest.prefix(19)) : digest
            repository = String(repository[..<at])
        }
        // A colon after the last slash starts a tag; one before it is a registry's port.
        if let colon = repository.lastIndex(of: ":"),
           repository[colon...].contains("/") == false {
            let tag = String(repository[repository.index(after: colon)...])
            version = version ?? tag
            repository = String(repository[..<colon])
        }
        var components = repository.split(separator: "/").map(String.init)
        var registry: String?
        if components.count > 1, let first = components.first,
           first.contains(".") || first.contains(":") || first == "localhost" {
            registry = first
            components.removeFirst()
        }
        let name = components.isEmpty ? reference : components.joined(separator: "/")
        let detail = [registry, version].compactMap { $0 }.joined(separator: " · ")
        return (name, detail.isEmpty ? nil : detail)
    }
}
