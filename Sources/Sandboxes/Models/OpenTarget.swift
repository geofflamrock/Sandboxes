import Foundation

/// Where a sandbox can be opened.
enum OpenTarget: String, CaseIterable, Identifiable {
    case terminal
    case claudeDesktop

    var id: Self { self }

    var name: String {
        switch self {
        case .terminal: "Terminal"
        case .claudeDesktop: "Claude Desktop"
        }
    }

    var title: String {
        "Open in \(name)"
    }
}
