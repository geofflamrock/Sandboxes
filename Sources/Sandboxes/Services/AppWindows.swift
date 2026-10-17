import AppKit
import SwiftUI

/// The app keeps running in the menu bar after its windows close. With none
/// open it leaves the Dock and the app switcher, and comes back when one opens.
@MainActor
enum AppWindows {
    enum Kind {
        case main
        case create
        case settings
    }

    static let mainID = "main"
    static let createID = "create"

    /// Opens the main window scene. Set from a view, since only views can
    /// reach SwiftUI's `openWindow`.
    static var openMain: (() -> Void)?
    /// Opens the New Sandbox window scene, set alongside `openMain`.
    static var openCreate: (() -> Void)?

    private struct WeakWindow {
        weak var window: NSWindow?
    }

    private static var windows: [Kind: WeakWindow] = [:]
    private static var observedWindows: Set<ObjectIdentifier> = []

    /// Opens the main window, or brings it forward, and activates the app.
    static func showMain() {
        show(.main) { openMain?() }
    }

    /// Opens the New Sandbox window, or brings it forward, and activates the app.
    static func showCreate() {
        show(.create) { openCreate?() }
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

    /// The user asked for the window, so make the app active and put the
    /// window in front. Without a window the app was menu bar only, and the
    /// switch back to a regular app takes a moment to go through; activating
    /// before then can be dropped, letting the app that was active take over
    /// again when the menu closes. So activate again once it has gone through.
    private static func bringToFront(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        activate()
        window.makeKeyAndOrderFront(nil)
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// `NSApp.activate()` only works when the active app yields to this one,
    /// which nothing does for an app that was menu bar only, so windows ended
    /// up behind other apps'. Force it, as the deprecated call still does.
    private static func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func leaveDockIfNoWindowsAreOpen() {
        // A minimized window isn't visible, but leaving the Dock would
        // take it with it, with no way back to it.
        guard !windows.values.contains(where: { $0.window.map { $0.isVisible || $0.isMiniaturized } == true }) else { return }
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
