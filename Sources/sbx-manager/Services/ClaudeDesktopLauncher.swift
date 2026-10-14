import AppKit
import SwiftUI

/// Opens a sandbox in Claude Desktop over SSH.
///
/// `sbx setup ssh` makes every sandbox reachable as `<name>.sbx`; a
/// `claude://code/new` link then asks Claude Desktop to add (or reuse) that SSH
/// connection and open a new session in the sandbox's workspace. Desktop asks
/// the user to confirm before it saves or selects the connection.
enum ClaudeDesktopLauncher {
    enum LaunchError: LocalizedError {
        case notInstalled

        var errorDescription: String? {
            "Claude Desktop isn't installed. Download it from claude.ai/download."
        }
    }

    /// Where a mountless sandbox from a Docker agent template keeps its files.
    private static let defaultFolder = "/home/agent/workspace"
    private static let managedSSHMarker = ">>> docker sandboxes (managed) >>>"

    static var applicationURL: URL? {
        URL(string: "claude://").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    static func open(_ sandbox: Sandbox) async throws {
        guard applicationURL != nil else {
            throw LaunchError.notInstalled
        }
        if !isSSHConfigured() {
            try await SbxCLI.runChecked(["setup", "ssh"])
        }
        NSWorkspace.shared.open(link(for: sandbox))
    }

    static func link(for sandbox: Sandbox) -> URL {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "ssh_host", value: "\(sandbox.name).sbx"),
            URLQueryItem(name: "ssh_folder", value: sandbox.workspaces.first ?? defaultFolder),
        ]
        return components.url!
    }

    /// Whether `sbx setup ssh` has already added its block to ~/.ssh/config.
    private static func isSSHConfigured() -> Bool {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard let contents = try? String(contentsOf: config, encoding: .utf8) else {
            return false
        }
        return contents.contains(managedSSHMarker)
    }
}

/// Claude Desktop's own app icon, falling back to a symbol if it isn't installed.
struct ClaudeDesktopIcon: View {
    private static let icon: NSImage? = ClaudeDesktopLauncher.applicationURL
        .map { NSWorkspace.shared.icon(forFile: $0.path) }

    var body: some View {
        if let icon = Self.icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "sparkle")
        }
    }
}
