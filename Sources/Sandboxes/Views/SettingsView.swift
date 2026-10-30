import SwiftUI
import AppKit
import ServiceManagement

/// Settings, with general options in one tab and sbx in another.
struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsView()
            }
            Tab("sbx", systemImage: "terminal", value: SettingsTab.sbx) {
                SbxSettingsView()
            }
            // Other builds don't check for updates, so this lets them try it.
            if AppInfo.buildLabel != nil {
                Tab("Development", systemImage: "hammer", value: SettingsTab.development) {
                    DevelopmentSettingsView()
                }
            }
        }
        .background(WindowReader(kind: .settings))
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(ApprovalNotifier.enabledKey) private var notifiesAboutApprovals = true
    @AppStorage(EnvironmentStore.directoryKey) private var environmentsDirectory = ""
    @Environment(UpdateChecker.self) private var updates
    @Environment(EnvironmentStore.self) private var environments
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Notify me when a sandbox is waiting for approval", isOn: $notifiesAboutApprovals)
                Toggle("Open at login", isOn: Binding(
                    get: { loginItemStatus == .enabled || loginItemStatus == .requiresApproval },
                    set: setOpensAtLogin
                ))
                if loginItemStatus == .requiresApproval {
                    LabeledContent("Allow Sandboxes to open at login in System Settings.") {
                        Button("Open Login Items…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let loginItemError {
                        Text("Couldn't change whether Sandboxes opens at login: \(loginItemError)")
                    }
                    Text("Sandboxes keeps running in the menu bar when you close its window, so it can notify you. Click a notification to review the request. Choose how notifications appear in System Settings › Notifications.")
                }
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text((EnvironmentStore.directory.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(EnvironmentStore.directory.path)
                        Button("Choose…") {
                            if let url = OpenPanel.choose(directories: true, prompt: "Choose", message: "Choose the folder new environment files are saved in.").first {
                                environmentsDirectory = url.path
                            }
                        }
                        if !environmentsDirectory.isEmpty {
                            Button("Use Default") { environmentsDirectory = "" }
                        }
                    }
                }
            } header: {
                Text("Environment Files")
            } footer: {
                Text("Environment files are saved here, one folder each. Keep it outside the folders sandboxes mount, so an agent can't change the commands an environment file runs on your Mac.")
                    .foregroundStyle(.secondary)
            }

            if updates.isRunning {
                Section {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updates.checksAutomatically },
                        set: { updates.setChecksAutomatically($0) }
                    ))
                    LabeledContent("Look for a newer version now.") {
                        Button("Check Now") {
                            updates.checkForUpdates()
                        }
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Shows in the sidebar and menu bar when a newer version is on GitHub. Updates are checked before they're installed, and Sandboxes reopens when it's done.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: notifiesAboutApprovals) { _, isOn in
            if isOn {
                ApprovalNotifier.shared.requestAuthorization()
            }
        }
        .onChange(of: environmentsDirectory) {
            environments.refresh()
        }
        .onAppear {
            // It can change in System Settings while Settings is closed.
            loginItemStatus = SMAppService.mainApp.status
        }
    }

    private func setOpensAtLogin(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItemStatus = SMAppService.mainApp.status
    }
}

/// Settings › Development, only in builds that aren't releases.
private struct DevelopmentSettingsView: View {
    @AppStorage(UpdateChecker.forceEnabledKey) private var forcesUpdateChecks = false
    @AppStorage(UpdateChecker.repositoryKey) private var updateRepository = ""
    @AppStorage(SandboxSidebar.hidesVersionBadgeKey) private var hidesVersionBadge = false
    @Environment(UpdateChecker.self) private var updates

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates in this build", isOn: $forcesUpdateChecks)
                if forcesUpdateChecks {
                    TextField("Repository", text: $updateRepository, prompt: Text(UpdateChecker.defaultRepository))
                    LabeledContent {
                        Button("Check Now") {
                            updates.checkForUpdates()
                        }
                        .disabled(!updates.isRunning)
                    } label: {
                        if updates.isRunning {
                            Text("Opens Sparkle's update window.")
                        } else {
                            Text("Sparkle can't start without a public key in Info.plist (SUPublicEDKey).")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Only in builds that aren't releases. Sparkle compares build numbers, so a local build (build 1) sees the latest release as an update, but builds from CI don't. Turning this off takes effect the next time Sandboxes opens.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hide the version badge", isOn: $hidesVersionBadge)
            } header: {
                Text("Screenshots")
            } footer: {
                Text("Hides the build's badge at the bottom of the sidebar, so screenshots don't show that this isn't a release.")
                    .foregroundStyle(.secondary)
            }

            WindowSizeSection()
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: forcesUpdateChecks) { _, isOn in
            if isOn {
                updates.start()
            }
        }
    }
}

/// Settings › Development › Window Size, for taking screenshots of the main
/// window or the New Sandbox window at a set size.
private struct WindowSizeSection: View {
    private struct Preset: Identifiable {
        let width: Int
        let height: Int
        let ratio: String

        var id: String { "\(width)x\(height)" }
    }

    private static let presets = [
        Preset(width: 1280, height: 800, ratio: "16:10"),
        Preset(width: 1440, height: 900, ratio: "16:10"),
        Preset(width: 1280, height: 720, ratio: "16:9"),
        Preset(width: 1600, height: 900, ratio: "16:9"),
        Preset(width: 1024, height: 768, ratio: "4:3"),
    ]

    @State private var window = AppWindows.Kind.main
    // Text rather than numbers, since a number field only updates when
    // editing ends, and clicking Apply doesn't end it.
    @State private var width = "1280"
    @State private var height = "800"
    @State private var currentSize: CGSize?

    var body: some View {
        Section {
            Picker("Window", selection: $window) {
                Text("Sandboxes").tag(AppWindows.Kind.main)
                Text("New Sandbox").tag(AppWindows.Kind.create)
            }
            LabeledContent("Current size") {
                if let currentSize {
                    Text("\(Int(currentSize.width.rounded())) × \(Int(currentSize.height.rounded()))")
                        .monospacedDigit()
                } else {
                    Text("Not open")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Preset") {
                Menu("Resize") {
                    ForEach(Self.presets) { preset in
                        Button("\(preset.width) × \(preset.height) (\(preset.ratio))") {
                            width = String(preset.width)
                            height = String(preset.height)
                            apply()
                        }
                    }
                }
                .fixedSize()
            }
            .disabled(currentSize == nil)
            LabeledContent("Custom size") {
                HStack(spacing: 4) {
                    TextField("Width", text: $width)
                        .frame(width: 60)
                        .onSubmit(apply)
                    Text("×")
                    TextField("Height", text: $height)
                        .frame(width: 60)
                        .onSubmit(apply)
                    Button("Apply", action: apply)
                        .disabled(customSize == nil)
                }
                .labelsHidden()
                .multilineTextAlignment(.trailing)
            }
            .disabled(currentSize == nil)
        } header: {
            Text("Window Size")
        } footer: {
            Text("Sizes are in points and include the title bar. On a Retina display, a screenshot of the window has twice as many pixels each way, plus its shadow unless you hold Option as you click the window. Sizes below the window's minimum are raised to it.")
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onChange(of: window) { refresh() }
        // Settings becomes key again when the user comes back to it, after
        // opening or closing the window.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    private var customSize: CGSize? {
        guard let width = Int(width.trimmingCharacters(in: .whitespaces)), width > 0,
              let height = Int(height.trimmingCharacters(in: .whitespaces)), height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    private func apply() {
        guard let customSize else { return }
        AppWindows.resize(window, to: customSize)
        refresh()
    }

    private func refresh() {
        currentSize = AppWindows.size(of: window)
    }
}
