import Foundation

/// Where a sandbox can be opened.
enum OpenTarget: String, CaseIterable, Identifiable {
    case terminal
    case claudeDesktop

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: "Open in Terminal"
        case .claudeDesktop: "Open in Claude Desktop"
        }
    }
}
