import Foundation

/// A setting of Docker Sandboxes itself, from `sbx settings ls`, such as
/// `proxy` or `kit.requireSignature`. Not one of this app's settings.
struct SbxSetting: Identifiable, Hashable {
    /// How sbx parses a value given to `sbx settings set`.
    enum ValueType: Hashable {
        case bool
        case int
        case float
        case string
        case json
        case other(String)

        init(_ name: String) {
            switch name.lowercased() {
            case "bool", "boolean": self = .bool
            case "int", "integer": self = .int
            case "float", "number", "double": self = .float
            case "string", "": self = .string
            case "json", "object", "array": self = .json
            default: self = .other(name)
            }
        }

        var title: String {
            switch self {
            case .bool: "Boolean"
            case .int: "Integer"
            case .float: "Number"
            case .string: "Text"
            case .json: "JSON"
            case let .other(name): name
            }
        }
    }

    /// Where the value in use comes from.
    enum Source: Hashable {
        case `default`
        /// An environment variable, which wins over an override.
        case environment
        /// Set with `sbx settings set`.
        case override
        /// sbx couldn't evaluate it, such as when administrator settings
        /// can't be fetched.
        case unavailable
        case other(String)

        init(_ name: String) {
            switch name.lowercased() {
            case "default", "": self = .default
            case "envvar", "env", "environment": self = .environment
            case "override", "user": self = .override
            case "unavailable": self = .unavailable
            default: self = .other(name)
            }
        }

        var title: String {
            switch self {
            case .default: "Default"
            case .environment: "Environment"
            case .override: "Set"
            case .unavailable: "Unavailable"
            case let .other(name): name.capitalized
            }
        }
    }

    let key: String
    var type: ValueType
    /// The value in use, as `sbx settings set` takes it: `true`, `10g` or
    /// compact JSON. Nil when sbx couldn't evaluate it.
    var value: String?
    var defaultValue: String?
    var source: Source
    /// The variable that overrides it, such as `DOCKER_SANDBOXES_KIT_ALLOW_LOCAL`.
    var environmentVariable: String?
    var description: String
    /// Whether the daemon has to restart before a change applies everywhere.
    var requiresRestart: Bool
    /// Why sbx couldn't evaluate it.
    var error: String?

    var id: String { key }

    /// The part of the key before the first dot, such as "kit", which the
    /// Settings page groups by.
    var group: String {
        String(key.split(separator: ".", maxSplits: 1).first ?? Substring(key))
    }

    var isAvailable: Bool { source != .unavailable && value != nil }
    var isOverridden: Bool { source == .override }

    var boolValue: Bool? {
        switch value?.lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    static let listArguments = ["settings", "ls", "--json"]

    var getArguments: [String] { ["settings", "get", key, "--json"] }

    /// `--` so a value such as `-1` isn't taken for a flag.
    func setArguments(_ value: String) -> [String] {
        ["settings", "set", key, "--", value]
    }

    var unsetArguments: [String] { ["settings", "unset", key] }

    static func fetch() async throws -> [SbxSetting] {
        let output = try await SbxCLI.runChecked(listArguments)
        return SbxSettingParser.parseList(output)
    }

    /// The setting as sbx evaluates it now, with its full value.
    func fetchLatest() async throws -> SbxSetting? {
        let output = try await SbxCLI.runChecked(getArguments)
        return SbxSettingParser.parseList(output).first { $0.key == key }
    }
}

/// Parses `sbx settings ls --json` and `sbx settings get KEY --json`, which
/// print an array of records and a single record, such as:
///
///     {"key": "proxy", "type": "string", "value": "", "default": "",
///      "source": "default", "requires_restart": true, "env_var": "…",
///      "description": "…"}
///
/// A setting sbx can't evaluate has no value, `"source": "unavailable"` and
/// an `error`.
enum SbxSettingParser {
    static func parseList(_ output: String) -> [SbxSetting] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip any warnings printed before the JSON.
        guard let start = trimmed.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let data = String(trimmed[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        let records: [[String: Any]]
        if let array = json as? [[String: Any]] {
            records = array
        } else if let object = json as? [String: Any] {
            // A single setting, or a list under a key such as "settings".
            if let nested = SandboxListParser.value(in: object, for: ["settings", "items", "data"]) as? [[String: Any]] {
                records = nested
            } else {
                records = [object]
            }
        } else {
            records = []
        }
        return records.compactMap(setting).sorted { $0.key < $1.key }
    }

    private static func setting(_ record: [String: Any]) -> SbxSetting? {
        guard let key = text(record, ["key", "name"]) else { return nil }
        let typeName = text(record, ["type", "kind"]) ?? ""
        let sourceName = text(record, ["source", "origin"]) ?? ""
        return SbxSetting(
            key: key,
            type: SbxSetting.ValueType(typeName),
            value: SandboxListParser.value(in: record, for: ["value", "evaluated", "current"]).flatMap(valueText),
            defaultValue: SandboxListParser.value(in: record, for: ["default", "defaultValue"]).flatMap(valueText),
            source: SbxSetting.Source(sourceName),
            environmentVariable: text(record, ["env_var", "envVar", "env"]),
            description: text(record, ["description", "help"]) ?? "",
            requiresRestart: bool(SandboxListParser.value(in: record, for: ["requires_restart", "restart", "restartRequired"])),
            error: text(record, ["error"])
        )
    }

    /// A value as `sbx settings set` takes it: strings as they are, and
    /// everything else as compact JSON, such as `true`, `5` or `["docker.io/"]`.
    static func valueText(_ value: Any) -> String? {
        if value is NSNull { return nil }
        if let string = value as? String { return string }
        return json(value, pretty: false)
    }

    /// JSON for `value`, keeping slashes as they are so URLs stay readable.
    static func json(_ value: Any, pretty: Bool) -> String? {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `text` reformatted with indentation, or as it is if it isn't JSON.
    static func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let pretty = json(value, pretty: true)
        else { return text }
        return pretty
    }

    private static func text(_ record: [String: Any], _ keys: [String]) -> String? {
        guard let string = SandboxListParser.string(SandboxListParser.value(in: record, for: keys)),
              !string.isEmpty
        else { return nil }
        return string
    }

    private static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let string = value as? String {
            return ["true", "yes", "1"].contains(string.lowercased())
        }
        return false
    }
}
