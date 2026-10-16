import SwiftUI
import AppKit

@main
struct SandboxesApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var recents = RecentsStore()
    @State private var environments = EnvironmentStore()

    /// Owned by the app delegate, since it outlives the window.
    private var store: SandboxStore { appDelegate.store }

    var body: some Scene {
        Window("Sandboxes", id: AppWindows.mainID) {
            ContentView()
                .environment(store)
                .environment(recents)
                .environment(environments)
                .frame(minWidth: 720, minHeight: 440)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Sandboxes") {
                    // The standard panel shows "Version <applicationVersion> (<version>)".
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: AppInfo.version,
                        .version: AppInfo.aboutPanelBuild,
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Sandbox…") {
                    store.presentCreate()
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            MenuBarMenu()
                .environment(store)
        } label: {
            MenuBarLabel()
                .environment(store)
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SandboxStore()
    private var refreshTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        ApprovalNotifier.shared.register(store)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without this, App Nap stretches the wait between checks for
        // pending approvals while the window is closed, delaying
        // notifications by minutes.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Checking for network requests waiting for approval"
        )
        refreshTask = Task { [store] in
            await store.refreshPeriodically()
        }
    }

    /// Keeps running in the menu bar, so notifications still arrive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Reopens the window when the app is opened again, such as from Finder.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        AppWindows.showMain()
        return false
    }
}
