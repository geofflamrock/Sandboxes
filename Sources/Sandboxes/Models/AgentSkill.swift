import Foundation

/// A skill in sbx's shared skills store, which sandboxes link into their
/// agent's skills directory when they start.
struct AgentSkill: Identifiable, Hashable {
    /// Where a skill came from, which decides whether `sbx skills update`
    /// can refresh it.
    enum Source: Hashable {
        /// Added with `sbx skills add`, from this Git repository.
        case repository(String)
        /// Imported from an agent's skills folder on this Mac.
        case imported
        /// sbx's record of sources couldn't be read.
        case unknown
    }

    let name: String
    /// From the `description` in the skill's SKILL.md.
    var description: String?
    var source: Source
    /// The commit it was added or last updated from, for a skill from a repository.
    var commit: String?
    /// The skill's folder in the store, when sbx reports where the store is.
    var folder: URL?

    var id: String { name }

    /// `sbx skills update` only works for skills added from a repository.
    var canUpdate: Bool {
        if case .imported = source { return false }
        return true
    }

    var removeArguments: [String] {
        ["skills", "rm", name, "--force"]
    }

    var updateArguments: [String] {
        ["skills", "update", name]
    }

    static let listArguments = ["skills", "ls", "--json"]

    /// Updates every skill added from a repository.
    static let updateAllArguments = ["skills", "update"]

    /// Lists what `sbx skills import` would copy, without copying anything.
    static let importPreviewArguments = ["skills", "import", "--dry-run"]

    /// The app shows the preview first, so sbx doesn't need to ask before replacing.
    static let importArguments = ["skills", "import", "--force"]

    /// The skills in the store, with what their files say about them.
    static func fetch() async throws -> [AgentSkill] {
        let output = try await SbxCLI.runChecked(listArguments)
        let list = try SkillListParser.parse(output)
        let store = list.store.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        let records = store.flatMap(SkillSources.records(forStore:))
        return list.names.map { name in
            let source: Source
            if let records {
                source = records[name].map { .repository($0.repository) } ?? .imported
            } else {
                source = .unknown
            }
            let folder = store?.appendingPathComponent(name, isDirectory: true)
            let description = folder.flatMap { SkillFile.description(at: $0.appendingPathComponent("SKILL.md")) }
            return AgentSkill(name: name, description: description, source: source, commit: records?[name]?.commit, folder: folder)
        }
    }
}

/// What's entered in the Add Skills sheet.
struct SkillDraft {
    /// A Git URL, or a GitHub `owner/repository`.
    var repository = ""
    /// Skill names separated by commas or spaces. Empty adds every skill in the repository.
    var skills = ""

    var trimmedRepository: String { repository.trimmingCharacters(in: .whitespacesAndNewlines) }

    var skillNames: [String] {
        skills
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
    }

    func addArguments(replacing: Bool) -> [String] {
        var arguments = ["skills", "add", trimmedRepository]
        for skill in skillNames {
            arguments += ["--skill", skill]
        }
        if replacing {
            arguments.append("--force")
        }
        return arguments
    }

    var commandLine: String {
        (["sbx"] + addArguments(replacing: false)).map(CreateSandboxRequest.quoteIfNeeded).joined(separator: " ")
    }
}

/// How a new sandbox's agent sees the shared skills store, from `sbx create --skills`.
enum SkillsMode: String, CaseIterable, Identifiable {
    case readOnly = "readonly"
    case readWrite = "readwrite"
    case off

    var id: Self { self }

    var title: String {
        switch self {
        case .readOnly: "Read Only"
        case .readWrite: "Read and Write"
        case .off: "Off"
        }
    }

    var explanation: String {
        switch self {
        case .readOnly:
            "The store's skills are linked into the agent's skills folder, which stays writable so kits can add their own."
        case .readWrite:
            "The store is mounted over the agent's skills folder, so skills the agent adds or changes are shared with other sandboxes."
        case .off:
            "The agent only has skills from its kits."
        }
    }
}

/// Reads `sbx skills ls --json`, which looks like
/// `{"store": "/path", "skills": ["name", …]}`. Lists of records with a
/// name, and the table output, are accepted too.
enum SkillListParser {
    struct List: Hashable {
        var store: String?
        var names: [String]
    }

    struct ParseError: LocalizedError {
        let output: String
        var errorDescription: String? {
            "Couldn't read the output of sbx skills ls --json:\n\(output)"
        }
    }

    static func parse(_ output: String) throws -> List {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" || trimmed.hasPrefix("No skills") {
            return List(store: nil, names: [])
        }
        guard let start = trimmed.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let data = String(trimmed[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return try parseTable(trimmed)
        }

        var store: String?
        var items: [Any] = []
        if let object = json as? [String: Any] {
            store = SandboxListParser.string(SandboxListParser.value(in: object, for: ["store", "storePath", "path", "dir"]))
            switch SandboxListParser.value(in: object, for: ["skills", "items", "entries"]) {
            case let list as [Any]: items = list
            case let map as [String: Any]: items = map.keys.map { $0 as Any }
            default: break
            }
        } else if let list = json as? [Any] {
            items = list
        } else {
            throw ParseError(output: trimmed)
        }

        var seen = Set<String>()
        let names = items.compactMap { item -> String? in
            if let name = item as? String { return name }
            guard let record = item as? [String: Any] else { return nil }
            if store == nil {
                store = SandboxListParser.string(SandboxListParser.value(in: record, for: ["store", "storePath"]))
            }
            return SandboxListParser.string(SandboxListParser.value(in: record, for: ["name", "skill", "id"]))
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return List(store: store, names: names)
    }

    /// `SKILL  STORE` columns, for an sbx without `--json`.
    private static func parseTable(_ text: String) throws -> List {
        let rows = text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            .filter { !$0.isEmpty }
        guard let header = rows.first, header.first?.uppercased() == "SKILL" else {
            throw ParseError(output: text)
        }
        let body = rows.dropFirst()
        return List(store: body.first.flatMap { $0.count > 1 ? $0[1] : nil }, names: body.map { $0[0] })
    }
}

/// sbx's record of which repository each added skill came from. It isn't
/// documented, so anything unexpected is treated as unknown rather than
/// as a skill that can't be updated.
private enum SkillSources {
    struct Record {
        var repository: String
        var commit: String?
    }

    /// Records by skill name, or nil when sbx's record can't be read.
    static func records(forStore store: URL) -> [String: Record]? {
        let metadata = store.deletingLastPathComponent().appendingPathComponent(store.lastPathComponent + "-metadata")
        guard let data = try? Data(contentsOf: metadata.appendingPathComponent("sources.json")) else {
            // sbx starts the record when it first adds a skill from a repository.
            let fileManager = FileManager.default
            return fileManager.fileExists(atPath: store.path) && !fileManager.fileExists(atPath: metadata.path) ? [:] : nil
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let skills = object["skills"] as? [String: Any]
        else { return nil }
        var records: [String: Record] = [:]
        for (name, value) in skills {
            if let record = value as? [String: Any],
               let repository = SandboxListParser.string(SandboxListParser.value(in: record, for: ["repository", "repo", "url", "source"])) {
                let commit = SandboxListParser.string(SandboxListParser.value(in: record, for: ["commit", "sha", "revision", "ref"]))
                records[name] = Record(repository: repository, commit: commit)
            }
        }
        return records
    }
}

/// Reads a SKILL.md: its front matter, and the instructions after it.
enum SkillFile {
    /// The text after the front matter, or all of it when there's none.
    static func instructions(in text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" })
        else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The instructions in the SKILL.md in `folder`, or nil when it can't be
    /// read. Being async, it reads the file off the main actor.
    static func instructions(inSkillAt folder: URL) async -> String? {
        let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)
        return text.map(instructions(in:))
    }

    /// The `description` between the opening `---` lines, including a
    /// folded or literal block (`>` or `|`) on the lines after it.
    static func description(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)[...]
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return nil }
        lines = lines.dropFirst()
        while let line = lines.first, line.trimmingCharacters(in: .whitespacesAndNewlines) != "---" {
            lines = lines.dropFirst()
            guard line.hasPrefix("description:") else { continue }
            var value = line.dropFirst("description:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || value.hasPrefix(">") || value.hasPrefix("|") {
                var block: [String] = []
                while let next = lines.first, next.hasPrefix(" ") || next.hasPrefix("\t") {
                    block.append(next.trimmingCharacters(in: .whitespacesAndNewlines))
                    lines = lines.dropFirst()
                }
                value = block.joined(separator: " ")
            } else if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

