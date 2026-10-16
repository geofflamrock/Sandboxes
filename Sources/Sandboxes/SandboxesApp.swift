import SwiftUI
import AppKit

@main
struct SandboxesApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var recents = RecentsStore()

    /// Owned by the app delegate, since it outlives the window.
    private var store: SandboxStore { appDelegate.store }
    private var updates: UpdateChecker { appDelegate.updates }

    var body: some Scene {
        Window("Sandboxes", id: AppWindows.mainID) {
            ContentView()
                .environment(store)
                .environment(updates)
                .environment(recents)
                .environment(appDelegate.sbxStatus)
                .environment(appDelegate.secrets)
                .environment(appDelegate.mcpServers)
                .environment(appDelegate.environments)
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
                Button("Secrets") {
                    store.selection = .secrets
                    AppWindows.showMain()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Button("MCP Servers") {
                    store.selection = .mcpServers
                    AppWindows.showMain()
                }
            }
            // The selected sandbox's actions, which are also in the sandbox's
            // toolbar and context menu.
            CommandMenu("Sandbox") {
                SandboxMenu()
                    .environment(store)
                    .environment(appDelegate.mcpServers)
                    .environment(appDelegate.sbxStatus)
            }
            CommandGroup(after: .help) {
                RunDiagnosticsButton(sbxStatus: appDelegate.sbxStatus)
            }
        }

        // A window rather than a sheet, so its tab view's tabs sit in a title bar.
        Window("New Sandbox", id: AppWindows.createID) {
            CreateSandboxView()
                .environment(store)
                .environment(recents)
                .environment(appDelegate.mcpServers)
                .environment(appDelegate.environments)
        }
        .defaultSize(width: 640, height: 700)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        // A window like New Sandbox, which it's an alternative to.
        Window("New Sandbox from Environment", id: AppWindows.createFromEnvironmentID) {
            CreateFromEnvironmentView()
                .environment(store)
                .environment(appDelegate.environments)
        }
        .defaultSize(width: 640, height: 660)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        MenuBarExtra {
            MenuBarMenu()
                .environment(store)
                .environment(updates)
        } label: {
            MenuBarLabel()
                .environment(store)
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(updates)
                .environment(appDelegate.sbxStatus)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SandboxStore()
    let updates = UpdateChecker()
    let sbxStatus = SbxStatus()
    let secrets: SecretStore
    let mcpServers: MCPServerStore
    let environments = EnvironmentStore()
    private var refreshTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    override init() {
        let secrets = SecretStore()
        self.secrets = secrets
        mcpServers = MCPServerStore(secrets: secrets)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        ApprovalNotifier.shared.register(store)
        // When sbx stops listing sandboxes, find out why straight away, so
        // the home page can say to start the daemon or sign in.
        store.onLoadFailed = { [sbxStatus] in
            Task { await sbxStatus.sandboxesFailedToLoad() }
        }
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
        updateTask = Task { [updates] in
            await updates.checkPeriodically()
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

/// The Sandbox menu: actions on the sandbox selected in the sidebar, or the
/// same items disabled when none is.
private struct SandboxMenu: View {
    @Environment(SandboxStore.self) private var store

    var body: some View {
        if let sandbox = store.selectedSandbox {
            SandboxActionButtons(sandbox: sandbox)
        } else {
            Group {
                Button("Start") {}
                Button("Open Shell") {}
                Divider()
                Button("Load MCP Server") {}
                Button("Unload MCP Server") {}
                Divider()
                Button("Remove…") {}
            }
            .disabled(true)
        }
    }
}

/// Help › Run sbx Diagnostics…: opens Settings › sbx and runs the checks again.
private struct RunDiagnosticsButton: View {
    let sbxStatus: SbxStatus
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Run sbx Diagnostics…") {
            SettingsTab.show(.sbx, openSettings)
            Task { await sbxStatus.diagnose() }
        }
    }
}
