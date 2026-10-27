import Foundation

/// A folder on the Mac that a kit shares with a sandbox (`host-mount@1`),
/// as `sbx inspect` reports it: the one chosen with `--mount`, or else the
/// one Docker Sandboxes manages for the kit.
struct SandboxHostMount: Identifiable, Hashable {
    let sandboxPath: String
    let hostPath: String

    var id: String { sandboxPath }

    /// Docker Sandboxes keeps the folders it manages under its own
    /// Application Support folder, keyed by kit and path.
    var isManaged: Bool { hostPath.contains("/com.docker.sandboxes/sandboxes/kit-host-mounts/") }

    static func fetch(for sandbox: String) async throws -> [SandboxHostMount] {
        parse(try await SbxCLI.runChecked(["inspect", sandbox, "--json"]))
    }

    /// The `mounts` in `sbx inspect --json` output, which is a map from the
    /// sandbox path to the host folder in v0.50.0. A list of records is
    /// accepted too, in case a later version changes it.
    static func parse(_ output: String) -> [SandboxHostMount] {
        guard let record = document(in: output) as? [String: Any] else { return [] }
        var mounts: [SandboxHostMount] = []
        switch SandboxListParser.value(in: record, for: ["mounts", "hostMounts", "host_mounts"]) {
        case let map as [String: Any]:
            for (sandboxPath, value) in map {
                if let hostPath = SandboxListParser.string(value), !hostPath.isEmpty {
                    mounts.append(SandboxHostMount(sandboxPath: sandboxPath, hostPath: hostPath))
                }
            }
        case let list as [[String: Any]]:
            for item in list {
                guard let sandboxPath = text(item, ["path", "sandboxPath", "sandbox_path", "target", "destination"]),
                      let hostPath = text(item, ["host", "hostPath", "host_path", "source"])
                else { continue }
                mounts.append(SandboxHostMount(sandboxPath: sandboxPath, hostPath: hostPath))
            }
        default:
            break
        }
        return mounts.sorted { $0.sandboxPath < $1.sandboxPath }
    }

    private static func text(_ record: [String: Any], _ keys: [String]) -> String? {
        guard let value = SandboxListParser.string(SandboxListParser.value(in: record, for: keys)), !value.isEmpty
        else { return nil }
        return value
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
