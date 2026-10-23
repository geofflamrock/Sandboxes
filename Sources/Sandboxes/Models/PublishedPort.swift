import Foundation

/// A sandbox port published on the Mac, as `sbx ports --json` reports it.
struct PublishedPort: Identifiable, Hashable {
    var id: String { "\(hostAddress ?? "")→\(target)" }
    let hostIP: String?
    let hostPort: Int?
    let sandboxPort: Int
    let protocolName: String?

    /// sbx's Git daemon, which it publishes for a clone-mode sandbox's
    /// `sandbox-<name>` remote.
    static let gitDaemonPort = 9418

    /// Where it's reachable on the Mac, e.g. `127.0.0.1:49155`.
    var hostAddress: String? {
        guard let hostPort else { return nil }
        guard let hostIP, !hostIP.isEmpty else { return "localhost:\(hostPort)" }
        return hostIP.contains(":") ? "[\(hostIP)]:\(hostPort)" : "\(hostIP):\(hostPort)"
    }

    /// The sandbox side, e.g. `9418/tcp4`.
    var target: String {
        protocolName.map { "\(sandboxPort)/\($0)" } ?? String(sandboxPort)
    }

    /// What `sbx ports --unpublish` takes: `[HOST_IP:]HOST_PORT:SANDBOX_PORT[/PROTOCOL]`.
    var unpublishSpec: String? {
        guard let hostPort else { return nil }
        guard let hostIP, !hostIP.isEmpty else { return "\(hostPort):\(target)" }
        let host = hostIP.contains(":") ? "[\(hostIP)]" : hostIP
        return "\(host):\(hostPort):\(target)"
    }

    var isTCP: Bool {
        protocolName?.lowercased().hasPrefix("tcp") ?? true
    }

    /// The address to open in a browser. A port bound to every interface is
    /// opened on localhost.
    var browserURL: URL? {
        guard isTCP, let hostPort else { return nil }
        let host: String
        switch hostIP {
        case nil, "", "0.0.0.0", "::", "127.0.0.1", "::1": host = "localhost"
        case let ip?: host = ip.contains(":") ? "[\(ip)]" : ip
        }
        return URL(string: "http://\(host):\(hostPort)")
    }

    var isGitDaemon: Bool { sandboxPort == Self.gitDaemonPort }

    static func fetch(for sandbox: Sandbox) async throws -> [PublishedPort] {
        try PublishedPortParser.parse(try await SbxCLI.runChecked(["ports", sandbox.name, "--json"]))
    }

    /// Publishes `port`. sbx starts the sandbox first if it's stopped.
    static func publish(_ port: PortMapping, in sandbox: Sandbox) async throws {
        try await SbxCLI.runChecked(["ports", sandbox.name, "--publish", port.spec])
    }

    func unpublish(from sandbox: Sandbox) async throws {
        guard let unpublishSpec else { return }
        try await SbxCLI.runChecked(["ports", sandbox.name, "--unpublish", unpublishSpec])
    }
}

/// Parses `sbx ports --json`, which v0.49.1 reports as a list of
/// `host_ip`, `host_port`, `sandbox_port` and `protocol`. Other key spellings
/// and a wrapping object are accepted too, as for `sbx ls`.
enum PublishedPortParser {
    struct ParseError: LocalizedError {
        let output: String
        var errorDescription: String? {
            "Couldn't read the output of sbx ports --json:\n\(output)"
        }
    }

    static func parse(_ output: String) throws -> [PublishedPort] {
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
        if let object = json as? [String: Any],
           let nested = SandboxListParser.value(in: object, for: ["ports", "published_ports", "items", "data"]) {
            return ports(in: nested)
        }
        return ports(in: json)
    }

    static func ports(in value: Any?) -> [PublishedPort] {
        let items = value as? [Any] ?? value.map { [$0] } ?? []
        return items.compactMap { item in
            guard let mapping = item as? [String: Any] else { return nil }
            return port(from: mapping)
        }
    }

    private static func port(from mapping: [String: Any]) -> PublishedPort? {
        guard var sandboxPort = SandboxListParser.string(SandboxListParser.value(
            in: mapping, for: ["sandbox_port", "container_port", "private_port", "target", "port"]
        )) else {
            return nil
        }
        var protocolName = SandboxListParser.string(SandboxListParser.value(in: mapping, for: ["protocol", "proto", "type"]))
        // A port given as `8080/tcp`.
        if let slash = sandboxPort.firstIndex(of: "/") {
            protocolName = protocolName ?? String(sandboxPort[sandboxPort.index(after: slash)...])
            sandboxPort = String(sandboxPort[..<slash])
        }
        guard let sandboxPortNumber = Int(sandboxPort) else { return nil }
        let hostPort = SandboxListParser.string(SandboxListParser.value(
            in: mapping, for: ["host_port", "published_port", "public_port", "published"]
        )).flatMap { Int($0) }
        let hostIP = SandboxListParser.string(SandboxListParser.value(in: mapping, for: ["host_ip", "host_address", "ip", "address"]))
        return PublishedPort(
            hostIP: hostIP,
            hostPort: hostPort,
            sandboxPort: sandboxPortNumber,
            protocolName: protocolName?.isEmpty == false ? protocolName : nil
        )
    }
}
