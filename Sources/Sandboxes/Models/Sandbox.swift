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
    var id: String { name }
    let name: String
    let status: String
    let agent: String?
    let workspaces: [String]
    let createdAt: Date?
    /// Published ports, formatted for display, e.g. `127.0.0.1:54321 → 8080/tcp`.
    let ports: [String]
    /// The CPU limit recorded for the sandbox, if `sbx ls` reports one.
    let cpus: Double?
    /// The memory limit recorded for the sandbox in bytes, if `sbx ls` reports one.
    let memoryBytes: Int64?

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
        return Sandbox(
            name: name,
            status: string(value(in: record, for: ["status", "state"])) ?? "",
            agent: string(value(in: record, for: ["agent", "kit", "workload", "image", "template"])),
            workspaces: list(value(in: record, for: ["workspaces", "workspace", "paths", "path", "mounts"])),
            createdAt: date(value(in: record, for: ["created_at", "created", "creation_time", "created_time"])),
            ports: ports(value(in: record, for: ["ports", "published_ports", "port_mappings", "publish"])),
            cpus: number(resource(in: record, for: ["cpus", "cpu", "cpu_count", "cpu_limit", "vcpus", "num_cpus"])),
            memoryBytes: memoryBytes(in: record)
        )
    }

    /// Looks for a resource limit at the top level or in a nested
    /// `resources` or `limits` object.
    private static func resource(in record: [String: Any], for keys: [String]) -> Any? {
        if let found = value(in: record, for: keys) {
            return found
        }
        for container in ["resources", "limits", "resource_limits"] {
            if let nested = value(in: record, for: [container]) as? [String: Any],
               let found = resource(in: nested, for: keys) {
                return found
            }
        }
        return nil
    }

    private static func memoryBytes(in record: [String: Any]) -> Int64? {
        if let mebibytes = number(resource(in: record, for: ["memory_mib", "memory_mb", "mem_mib", "mem_mb"])) {
            return Int64(mebibytes * 1_048_576)
        }
        let value = resource(in: record, for: ["memory_bytes", "memory", "memory_limit", "mem", "mem_limit"])
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            // A bare number under a million is far too small to be bytes, so read it as MiB.
            let amount = number.doubleValue
            return Int64(amount < 1_000_000 ? amount * 1_048_576 : amount)
        }
        // A size with an optional unit, such as "8g", "512MiB" or "8589934592".
        guard let text = string(value)?.lowercased().filter({ $0 != " " }) else { return nil }
        let digits = text.prefix { $0.isNumber || $0 == "." }
        let units: [String: Double] = [
            "": 1, "b": 1,
            "k": 1024, "kb": 1024, "kib": 1024,
            "m": 1_048_576, "mb": 1_048_576, "mib": 1_048_576,
            "g": 1_073_741_824, "gb": 1_073_741_824, "gib": 1_073_741_824,
            "t": 1_099_511_627_776, "tb": 1_099_511_627_776, "tib": 1_099_511_627_776,
        ]
        guard let amount = Double(digits), let multiplier = units[String(text.dropFirst(digits.count))] else {
            return nil
        }
        return Int64(amount * multiplier)
    }

    /// Accepts RFC 3339 timestamps (with any number of fractional digits) and
    /// Unix timestamps in seconds or milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let seconds = number.doubleValue
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let text = value as? String, !text.isEmpty else { return nil }
        // ISO8601DateFormatter can't read Go's nanosecond precision, so drop the fraction.
        var trimmed = text
        if let dot = trimmed.firstIndex(of: ".") {
            let fractionEnd = trimmed[trimmed.index(after: dot)...].firstIndex { !$0.isNumber } ?? trimmed.endIndex
            trimmed.removeSubrange(dot..<fractionEnd)
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    private static func ports(_ value: Any?) -> [String] {
        let items = value as? [Any] ?? value.map { [$0] } ?? []
        return items.compactMap { item -> String? in
            guard let mapping = item as? [String: Any] else {
                return string(item)
            }
            guard let sandboxPort = string(Self.value(in: mapping, for: ["sandbox_port", "container_port", "private_port", "target", "port"])) else {
                return string(mapping)
            }
            var target = sandboxPort
            if let proto = string(Self.value(in: mapping, for: ["protocol", "proto", "type"])), !target.contains("/") {
                target += "/\(proto)"
            }
            guard let hostPort = string(Self.value(in: mapping, for: ["host_port", "published_port", "public_port", "published"])) else {
                return target
            }
            let hostIP = string(Self.value(in: mapping, for: ["host_ip", "host_address", "ip", "address"])) ?? ""
            let host = hostIP.isEmpty ? hostPort : hostIP.contains(":") ? "[\(hostIP)]:\(hostPort)" : "\(hostIP):\(hostPort)"
            return "\(host) → \(target)"
        }
        .filter { !$0.isEmpty }
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        return (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Looks up a value ignoring case, underscores and hyphens.
    static func value(in record: [String: Any], for keys: [String]) -> Any? {
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

    static func string(_ value: Any?) -> String? {
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
