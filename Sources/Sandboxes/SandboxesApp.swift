import SwiftUI
import AppKit

@main
struct SandboxesApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = SandboxStore()
    @State private var recents = RecentsStore()

    var body: some Scene {
        Window("Sandboxes", id: "main") {
            ContentView()
                .environment(store)
                .environment(recents)
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
                    store.isCreatePresented = true
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

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
