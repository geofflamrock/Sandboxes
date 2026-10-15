import Foundation

/// Ways to open a sandbox: running its agent in Terminal, or opening it in
/// Claude Desktop, which works with any sandbox whatever its agent.
enum OpenTarget: String, CaseIterable, Identifiable {
    case terminal
    case claudeDesktop

    var id: Self { self }

    /// What opening does, such as "Run Codex" or "Open in Claude Desktop".
    func title(for agent: Agent?) -> String {
        switch self {
        case .terminal: "Run \(agent?.displayName ?? "Agent")"
        case .claudeDesktop: "Open in Claude Desktop"
        }
    }

    /// The title with the app it opens in, for the open button's menu.
    func detailedTitle(for agent: Agent?) -> String {
        switch self {
        case .terminal: "\(title(for: agent)) in Terminal"
        case .claudeDesktop: title(for: agent)
        }
    }
}
