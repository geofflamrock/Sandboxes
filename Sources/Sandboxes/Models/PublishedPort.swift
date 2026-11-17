import Foundation

/// A sandbox port published on the Mac, as `sbx port ls --json` reports it.
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

    /// What `sbx port unpublish` (and `sbx ports --unpublish`) takes: `[HOST_IP:]HOST_PORT:SANDBOX_PORT[/PROTOCOL]`.
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

    /// Pass `usesPortCommand` from `SbxStatus.supportsPortCommand`: sbx v0.54.0
    /// added `sbx port ls|publish|unpublish` and deprecated `sbx ports`.
    static func listArguments(for sandbox: String, usesPortCommand: Bool) -> [String] {
        usesPortCommand ? ["port", "ls", sandbox, "--json"] : ["ports", sandbox, "--json"]
    }

    static func publishArguments(_ spec: String, for sandbox: String, usesPortCommand: Bool) -> [String] {
        usesPortCommand ? ["port", "publish", sandbox, spec] : ["ports", sandbox, "--publish", spec]
    }

    static func unpublishArguments(_ spec: String, for sandbox: String, usesPortCommand: Bool) -> [String] {
        usesPortCommand ? ["port", "unpublish", sandbox, spec] : ["ports", sandbox, "--unpublish", spec]
    }

    static func fetch(for sandbox: Sandbox, usesPortCommand: Bool) async throws -> [PublishedPort] {
        try PublishedPortParser.parse(try await SbxCLI.runChecked(
            listArguments(for: sandbox.name, usesPortCommand: usesPortCommand)
        ))
    }

    /// Publishes `port`. sbx starts the sandbox first if it's stopped.
    static func publish(_ port: PortMapping, in sandbox: Sandbox, usesPortCommand: Bool) async throws {
        try await SbxCLI.runChecked(publishArguments(port.spec, for: sandbox.name, usesPortCommand: usesPortCommand))
    }

    /// Removes only this mapping: with the host port given, sbx leaves the
    /// sandbox port's other host mappings alone.
    func unpublish(from sandbox: Sandbox, usesPortCommand: Bool) async throws {
        guard let unpublishSpec else { return }
        try await SbxCLI.runChecked(
            Self.unpublishArguments(unpublishSpec, for: sandbox.name, usesPortCommand: usesPortCommand)
        )
    }
}

/// Parses `sbx port ls --json` (`sbx ports --json` before v0.54.0), which
/// v0.49.1 to v0.54.0 report as a list of `host_ip`, `host_port`,
/// `sandbox_port` and `protocol`. Other key spellings and a wrapping object
/// are accepted too, as for `sbx ls`.
enum PublishedPortParser {
    struct ParseError: LocalizedError {
        let output: String
        var errorDescription: String? {
            "Couldn't read sbx's list of published ports:\n\(output)"
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
