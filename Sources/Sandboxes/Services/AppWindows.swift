import AppKit
import SwiftUI

/// The app keeps running in the menu bar after its windows close. With none
/// open it leaves the Dock and the app switcher, and comes back when one opens.
@MainActor
enum AppWindows {
    enum Kind {
        case main
        case settings
    }

    static let mainID = "main"

    /// Opens the main window scene. Set from a view, since only views can
    /// reach SwiftUI's `openWindow`.
    static var openMain: (() -> Void)?

    private struct WeakWindow {
        weak var window: NSWindow?
    }

    private static var windows: [Kind: WeakWindow] = [:]
    private static var observedWindows: Set<ObjectIdentifier> = []

    /// Opens the main window, or brings it forward, and activates the app.
    static func showMain() {
        show(.main) { openMain?() }
    }

    static func showSettings(_ openSettings: OpenSettingsAction) {
        show(.settings) { openSettings() }
    }

    /// Called by `WindowReader` when one of the app's windows appears.
    static func didOpen(_ window: NSWindow, as kind: Kind) {
        windows[kind] = WeakWindow(window: window)
        NSApp.setActivationPolicy(.regular)
        if observedWindows.insert(ObjectIdentifier(window)).inserted {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                // The window is still visible while it closes.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { leaveDockIfNoWindowsAreOpen() }
                }
            }
        }
        bringToFront(window)
    }

    private static func show(_ kind: Kind, open: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        open()
        if let window = windows[kind]?.window {
            bringToFront(window)
        }
    }

    /// Activating can be refused, or not take effect until the switch back to
    /// a regular app has gone through, which left windows behind other apps'.
    /// So put the window in front regardless, and activate again on the next
    /// turn of the run loop.
    private static func bringToFront(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.async {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private static func leaveDockIfNoWindowsAreOpen() {
        guard !windows.values.contains(where: { $0.window?.isVisible == true }) else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Tells `AppWindows` when the window showing this view appears.
struct WindowReader: NSViewRepresentable {
    let kind: AppWindows.Kind

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(kind: kind)
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let kind: AppWindows.Kind

        init(kind: AppWindows.Kind) {
            self.kind = kind
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                AppWindows.didOpen(window, as: kind)
            }
        }
    }
}
