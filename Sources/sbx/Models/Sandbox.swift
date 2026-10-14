import SwiftUI

enum SandboxState: Hashable {
    case running
    case stopped
    case transitioning
    case failed
    case unknown

    init(status: String) {
        let status = status.lowercased()
        func matches(_ words: String...) -> Bool { words.contains { status.contains($0) } }

        if status.isEmpty {
            self = .unknown
        } else if matches("error", "fail", "dead") {
            self = .failed
        } else if matches("starting", "stopping", "creating", "pending", "restarting", "removing", "provisioning") {
            self = .transitioning
        } else if matches("running") || status.hasPrefix("up") {
            self = .running
        } else if matches("stop", "exit", "created", "paused", "suspend") {
            self = .stopped
        } else {
            self = .unknown
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .stopped: .secondary
        case .transitioning: .orange
        case .failed: .red
        case .unknown: .gray
        }
    }
}

struct Sandbox: Identifiable, Hashable {
    struct Field: Hashable {
        let key: String
        let value: String
    }

    var id: String { name }
    let name: String
    let status: String
    let agent: String?
    let workspaces: [String]
    let ports: [String]
    /// Every field `sbx ls` reported, for the details view.
    let fields: [Field]

    var state: SandboxState { SandboxState(status: status) }

    var statusLabel: String {
        status.isEmpty ? "Unknown" : status.capitalized
    }
}

/// Parses `sbx ls --json`. The schema isn't documented, so this accepts a few
/// likely shapes and key spellings rather than a fixed `Decodable` model.
enum SandboxListParser {
    struct ParseError: LocalizedError {
        let output: String
        var errorDescription: String? {
            "Couldn't read the output of sbx ls --json:\n\(output)"
        }
    }

    static func parse(_ output: String) throws -> [Sandbox] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" {
            return []
        }
        // Skip any warnings printed before the JSON document.
        guard let start = trimmed.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let data = String(trimmed[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            throw ParseError(output: trimmed)
        }
        return records(in: json).compactMap(sandbox(from:))
    }

    private static func records(in json: Any) -> [[String: Any]] {
        if let array = json as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        guard let object = json as? [String: Any] else { return [] }
        for key in ["sandboxes", "items", "data", "results"] {
            if let nested = value(in: object, for: [key]) {
                return records(in: nested)
            }
        }
        if value(in: object, for: ["name"]) != nil {
            return [object]
        }
        // A map of sandbox name to details.
        return object.compactMap { key, value -> [String: Any]? in
            guard var record = value as? [String: Any] else { return nil }
            if Self.value(in: record, for: ["name"]) == nil {
                record["name"] = key
            }
            return record
        }
    }

    private static func sandbox(from record: [String: Any]) -> Sandbox? {
        guard let name = string(value(in: record, for: ["name", "sandbox", "id"])), !name.isEmpty else {
            return nil
        }
        let fields = record
            .compactMap { key, value in string(value).map { Sandbox.Field(key: key, value: $0) } }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }

        return Sandbox(
            name: name,
            status: string(value(in: record, for: ["status", "state"])) ?? "",
            agent: string(value(in: record, for: ["agent", "kit", "workload", "image", "template"])),
            workspaces: list(value(in: record, for: ["workspaces", "workspace", "paths", "path", "mounts"])),
            ports: list(value(in: record, for: ["ports", "publishedports", "published"])),
            fields: fields
        )
    }

    /// Looks up a value ignoring case, underscores and hyphens.
    private static func value(in record: [String: Any], for keys: [String]) -> Any? {
        func normalize(_ key: String) -> String {
            key.lowercased().filter { $0 != "_" && $0 != "-" }
        }
        let normalized = Dictionary(record.map { (normalize($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        for key in keys {
            if let value = normalized[normalize(key)], !(value is NSNull) {
                return value
            }
        }
        return nil
    }

    private static func list(_ value: Any?) -> [String] {
        if let array = value as? [Any] {
            return array.compactMap { string($0) }.filter { !$0.isEmpty }
        }
        return string(value).map { [$0] }?.filter { !$0.isEmpty } ?? []
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "Yes" : "No"
            }
            return number.stringValue
        case let array as [Any]:
            let items = array.compactMap { string($0) }
            return items.isEmpty ? nil : items.joined(separator: ", ")
        case let object as [String: Any]:
            if let preferred = Self.value(in: object, for: ["path", "name", "state", "status"]) {
                return string(preferred)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        default:
            return nil
        }
    }
}
