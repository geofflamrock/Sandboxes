import AppKit

/// The app keeps running in the menu bar after its window closes. Without a
/// window it leaves the Dock and the app switcher, and comes back when the
/// window reopens.
@MainActor
enum MainWindow {
    static let id = "main"

    /// Opens the window scene. Set from a view, since only views can reach
    /// SwiftUI's `openWindow`.
    static var open: (() -> Void)?

    /// Opens the window, or brings it forward, and activates the app.
    static func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        open?()
        for window in NSApp.windows where window.isMiniaturized {
            window.deminiaturize(nil)
        }
    }

    static func didOpen() {
        NSApp.setActivationPolicy(.regular)
    }

    static func didClose() {
        NSApp.setActivationPolicy(.accessory)
    }
}
