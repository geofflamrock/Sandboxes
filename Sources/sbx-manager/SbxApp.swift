import SwiftUI
import AppKit

@main
struct SbxApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = SandboxStore()
    @State private var recents = RecentsStore()

    var body: some Scene {
        Window("Docker Sandboxes Manager", id: "main") {
            ContentView()
                .environment(store)
                .environment(recents)
                .frame(minWidth: 720, minHeight: 440)
        }
        .commands {
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
