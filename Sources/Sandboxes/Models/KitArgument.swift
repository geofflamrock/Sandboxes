import Foundation
import Observation

/// An argument a kit declares under `args:`, which the installer can set with
/// `--kit-arg` (https://github.com/docker/sandbox-kit-spec/blob/main/docs/spec/SPEC-v3.md#6-args).
/// Values are always text: a kit narrows them with a list of choices or a pattern.
struct KitArgument: Hashable, Identifiable {
    enum Input {
        /// Choices of exactly `true` and `false`.
        case toggle
        case choice
        case text
    }

    let name: String
    var description: String?
    var defaultValue: String?
    var isRequired = false
    /// The exact values accepted, from `enum`.
    var choices: [String] = []
    /// A regular expression the whole value must match.
    var pattern: String?
    /// The environment variable the value is set as in the sandbox.
    var environmentVariable: String?
    /// The build argument the value is passed to when the kit is built.
    var buildArgument: String?

    var id: String { name }

    var input: Input {
        if Set(choices) == ["true", "false"] { return .toggle }
        return choices.isEmpty ? .text : .choice
    }

    /// Why `value` won't be accepted, if it won't. `nil` or an empty value
    /// leaves the argument to its default.
    func problem(with value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return isRequired && (defaultValue ?? "").isEmpty ? "“\(name)” is required." : nil
        }
        if !choices.isEmpty && !choices.contains(value) {
            return "“\(name)” must be one of \(choices.joined(separator: ", "))."
        }
        if let pattern, let regex = try? NSRegularExpression(pattern: "\\A(?:\(pattern))\\z") {
            let range = NSRange(value.startIndex..., in: value)
            if regex.firstMatch(in: value, range: range) == nil {
                return "“\(name)” must match \(pattern)."
            }
        }
        return nil
    }

    /// The name and value as `--kit-arg` takes them, aimed at one kit with
    /// its handle when another selected kit declares the same name.
    static func flag(name: String, value: String, handle: String?) -> String {
        let key = handle.map { "\($0).\(name)" } ?? name
        return "\(key)=\(value)"
    }

    /// Whether a workload can be inspected as a kit. A bare word, such as
    /// `claude`, is a built-in agent's name to sbx, and those aren't kits.
    static func isInspectable(workload: String) -> Bool {
        guard !workload.isEmpty, Agent.match(workload: workload)?.version != .builtIn else { return false }
        return workload.contains("/") || KitSource(reference: workload) != .registry
    }

    /// The name sbx knows a kit by when an argument is aimed at it with
    /// `handle.name=value`: the image's repository name, the folder or ZIP
    /// file's name, or a Git kit's folder, or else its repository's name
    /// (https://docs.docker.com/ai/sandboxes/customize/use-kits/#target-a-specific-kit).
    static func handle(for reference: String) -> String {
        var text = Substring(reference.trimmingCharacters(in: .whitespacesAndNewlines))
        switch KitSource(reference: reference) {
        case .git:
            if let hash = text.firstIndex(of: "#") {
                let fragment = text[text.index(after: hash)...]
                text = text[..<hash]
                for pair in fragment.split(separator: "&") where pair.hasPrefix("dir=") {
                    if let folder = pair.dropFirst(4).split(separator: "/").last {
                        return String(folder)
                    }
                }
            }
            var name = text.split(separator: "/").last ?? text
            if name.hasSuffix(".git") { name = name.dropLast(4) }
            return String(name)
        case .local:
            var name = text.split(separator: "/").last ?? text
            if name.lowercased().hasSuffix(".zip") { name = name.dropLast(4) }
            return String(name)
        case .registry:
            if let at = text.firstIndex(of: "@") { text = text[..<at] }
            var name = text.split(separator: "/").last ?? text
            if let colon = name.firstIndex(of: ":") { name = name[..<colon] }
            return String(name)
        }
    }
}

/// What `sbx kit inspect` reports about a kit that the New Sandbox window needs.
struct KitInspection: Hashable {
    let reference: String
    var displayName: String?
    /// `workload` or `mixin`.
    var kind: String?
    var arguments: [KitArgument] = []

    /// `sbx kit inspect` refuses a kit with a required argument unless it's
    /// given a value (as of v0.48.0), so this tries again with stand-in values
    /// until it accepts them, then reports the arguments as the kit declares them.
    static func fetch(_ reference: String) async throws -> KitInspection {
        var placeholders: [String: String] = [:]
        var required: Set<String> = []
        var attempts = 0
        while true {
            attempts += 1
            var arguments = ["kit", "inspect", reference, "--json"]
            for (name, value) in placeholders.sorted(by: { $0.key < $1.key }) {
                arguments += ["--kit-arg", "\(name)=\(value)"]
            }
            let result = try await SbxCLI.run(arguments)
            if result.succeeded {
                var inspection = try KitInspectionParser.parse(result.output, reference: reference)
                for index in inspection.arguments.indices where required.contains(inspection.arguments[index].name) {
                    inspection.arguments[index].isRequired = true
                }
                return inspection
            }
            let retry = KitArgumentPlaceholders.retry(after: result.output, current: placeholders)
            // Give up once a try asks for nothing new, or after a few tries.
            guard !retry.values.isEmpty, attempts < 20 else {
                throw SbxError.commandFailed(arguments: arguments, exitCode: result.exitCode, output: result.output)
            }
            placeholders.merge(retry.values) { $1 }
            required.formUnion(retry.required)
        }
    }
}

/// Stand-in values for `sbx kit inspect`, chosen from its complaints about
/// the values it was given: one for each required argument, the first
/// choice for an argument with choices, and a value matching the pattern
/// for one with a pattern.
enum KitArgumentPlaceholders {
    struct Retry {
        /// Values to add or change, by argument name.
        var values: [String: String] = [:]
        /// Arguments sbx said are required.
        var required: Set<String> = []
    }

    /// Tried in turn against an argument's pattern.
    private static let candidates = [
        "placeholder", "x", "0", "1", "1.0.0", "true", "main", "example",
        "example.com", "org/repo", "https://github.com/org/repo", "https://github.com/org/repo.git",
        "git@github.com:org/repo.git", "user@example.com", "https://example.com",
    ]

    static func retry(after output: String, current: [String: String]) -> Retry {
        var retry = Retry()
        // `kit arg "name" is required and no value was supplied`
        for match in output.matches(of: #/kit arg "([^"]+)" is required and no value was supplied/#) {
            let name = String(match.1)
            retry.required.insert(name)
            if current[name] == nil {
                retry.values[name] = candidates[0]
            }
        }
        // `kit arg "name": value "x" is not one of [a b]`
        for match in output.matches(of: #/kit arg "([^"]+)": value "(?:[^"\\]|\\.)*" is not one of \[([^\]]*)\]/#) {
            let name = String(match.1)
            if let choice = match.2.split(separator: " ").first.map(String.init), current[name] != choice {
                retry.values[name] = choice
            }
        }
        // `kit arg "name": value "x" does not match pattern "^…$"`, with the pattern quoted as Go does.
        for match in output.matches(of: #/kit arg "([^"]+)": value "(?:[^"\\]|\\.)*" does not match pattern "((?:[^"\\]|\\.)*)"/#) {
            let name = String(match.1)
            let pattern = unquoted(String(match.2))
            if let value = candidate(matching: pattern), current[name] != value {
                retry.values[name] = value
            }
        }
        return retry
    }

    private static func candidate(matching pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\A(?:\(pattern))\\z") else { return nil }
        return candidates.first { value in
            regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
    }

    /// Undoes the escaping Go's `%q` adds inside the quotes.
    private static func unquoted(_ text: String) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}

/// Inspects the kits picked in the New Sandbox window, keeping what it finds
/// so a kit isn't pulled again each time it's picked.
@MainActor
@Observable
final class KitInspector {
    enum Result: Hashable {
        case loading
        case loaded(KitInspection)
        case failed(String)
    }

    private(set) var results: [String: Result] = [:]

    /// Starts inspecting `reference` unless it's been inspected or is being
    /// inspected. A failed inspection is tried again.
    func inspect(_ reference: String) {
        switch results[reference] {
        case .loading, .loaded: return
        case .failed, nil: break
        }
        results[reference] = .loading
        Task {
            do {
                results[reference] = .loaded(try await KitInspection.fetch(reference))
            } catch {
                results[reference] = .failed(error.localizedDescription)
            }
        }
    }
}

/// Reads `sbx kit inspect --json`. Its shape isn't documented, so this looks
/// for the kit's descriptor at the top level or nested under a key such as
/// `spec`, and accepts `args` as a map of name to declaration or a list of
/// declarations with names. Components of a set, under `kits`, are skipped:
/// the set fixes their arguments or declares its own.
enum KitInspectionParser {
    struct ParseError: LocalizedError {
        let output: String
        var errorDescription: String? {
            "Couldn't read the output of sbx kit inspect --json:\n\(output)"
        }
    }

    private static let argumentKeys = ["args", "arguments", "inputs", "parameters"]

    static func parse(_ output: String, reference: String) throws -> KitInspection {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = document(in: trimmed) else {
            throw ParseError(output: trimmed)
        }
        let records = descriptorCandidates(in: json)
        let withArguments = records.first { !arguments(from: field($0, argumentKeys)).isEmpty }
        let descriptor = withArguments
            ?? records.first { field($0, ["schemaVersion", "kind", "displayName"]) != nil }
            ?? records.first
        guard let descriptor else { throw ParseError(output: trimmed) }
        return KitInspection(
            reference: reference,
            displayName: text(descriptor, ["displayName", "display_name", "title"]),
            kind: text(descriptor, ["kind"]),
            arguments: arguments(from: field(descriptor, argumentKeys))
        )
    }

    /// Every object in the document, shallowest first, apart from those
    /// inside `kits` or inside an argument map.
    private static func descriptorCandidates(in json: Any) -> [[String: Any]] {
        var found: [[String: Any]] = []
        var level: [Any] = [json]
        for _ in 0..<4 where !level.isEmpty {
            var next: [Any] = []
            for item in level {
                if let array = item as? [Any] {
                    next += array
                } else if let record = item as? [String: Any] {
                    found.append(record)
                    let skipped = Set((["kits"] + argumentKeys).map(normalize))
                    for (key, value) in record where !skipped.contains(normalize(key)) {
                        if value is [String: Any] || value is [Any] { next.append(value) }
                    }
                }
            }
            level = next
        }
        return found
    }

    private static func arguments(from value: Any?) -> [KitArgument] {
        var arguments: [KitArgument] = []
        if let map = value as? [String: Any] {
            for (name, declaration) in map {
                // A plain value is one a set has fixed, not one to ask for.
                if let declaration = declaration as? [String: Any] {
                    arguments.append(argument(named: name, declaration))
                } else if declaration is NSNull {
                    arguments.append(KitArgument(name: name))
                }
            }
        } else if let list = value as? [Any] {
            for case let declaration as [String: Any] in list {
                if let name = text(declaration, ["name", "key"]) {
                    arguments.append(argument(named: name, declaration))
                }
            }
        }
        return arguments.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func argument(named name: String, _ declaration: [String: Any]) -> KitArgument {
        var argument = KitArgument(name: name)
        argument.description = text(declaration, ["description", "help", "summary"])
        argument.defaultValue = scalar(field(declaration, ["default", "defaultValue"]))
        argument.isRequired = bool(field(declaration, ["required"])) ?? false
        argument.choices = (field(declaration, ["enum", "choices", "allowedValues", "allowed", "options"]) as? [Any] ?? [])
            .compactMap { scalar($0) }
        argument.pattern = text(declaration, ["pattern", "regex"])
        argument.environmentVariable = text(declaration, ["env", "envVar", "environment"])
        argument.buildArgument = text(declaration, ["buildArg", "buildArgument"])
        return argument
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

    private static func field(_ record: [String: Any], _ keys: [String]) -> Any? {
        SandboxListParser.value(in: record, for: keys)
    }

    private static func text(_ record: [String: Any], _ keys: [String]) -> String? {
        guard let value = scalar(field(record, keys))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// A value as sbx would take it on the command line: booleans as
    /// `true` and `false` rather than SandboxListParser's Yes and No.
    private static func scalar(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        default:
            return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool: bool
        case let number as NSNumber: number.boolValue
        case let string as String: ["true", "yes", "1"].contains(string.lowercased())
        default: nil
        }
    }

    private static func normalize(_ key: String) -> String {
        key.lowercased().filter { $0 != "_" && $0 != "-" }
    }
}
