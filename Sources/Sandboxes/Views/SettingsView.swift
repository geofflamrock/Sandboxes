import SwiftUI
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
        }
        .background(WindowReader(kind: .settings))
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(ApprovalNotifier.enabledKey) private var notifiesAboutApprovals = true
    @AppStorage(UpdateChecker.enabledKey) private var checksForUpdates = true
    @AppStorage(UpdateChecker.forceEnabledKey) private var forcesUpdateChecks = false
    @AppStorage(UpdateChecker.currentVersionKey) private var pretendVersion = ""
    @AppStorage(UpdateChecker.repositoryKey) private var updateRepository = ""
    @Environment(UpdateChecker.self) private var updates
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

            if UpdateChecker.isSupported {
                Section {
                    Toggle("Check for updates", isOn: $checksForUpdates)
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Shows when a newer version is on GitHub, with a link to download it.")
                        .foregroundStyle(.secondary)
                }
            }

            // Other builds don't check for updates, so this lets them try it.
            if AppInfo.buildLabel != nil {
                Section {
                    Toggle("Check for updates in this build", isOn: $forcesUpdateChecks)
                    if forcesUpdateChecks {
                        TextField("Pretend to be version", text: $pretendVersion, prompt: Text(AppInfo.version))
                            .onSubmit { Task { await updates.check() } }
                        TextField("Repository", text: $updateRepository, prompt: Text(UpdateChecker.defaultRepository))
                            .onSubmit { Task { await updates.check() } }
                        LabeledContent {
                            Button("Check Now") {
                                Task { await updates.check() }
                            }
                            .disabled(updates.status == .checking)
                        } label: {
                            UpdateStatusLabel(status: updates.status, update: updates.availableUpdate)
                        }
                    }
                } header: {
                    Text("Development Settings")
                } footer: {
                    Text("Only in builds that aren't releases. Pretend to be an older version to see the update in the sidebar and menu bar.")
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
        .onChange(of: checksForUpdates) {
            Task { await updates.check() }
        }
        .onChange(of: forcesUpdateChecks) {
            Task { await updates.check() }
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

/// The result of the last update check, for Settings › Development Settings.
private struct UpdateStatusLabel: View {
    let status: UpdateChecker.Status
    let update: UpdateChecker.Release?

    var body: some View {
        switch status {
        case .notChecked:
            Text("Not checked")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
        case .checked(let latest):
            if let update {
                Label("Version \(update.version) available", systemImage: "arrow.down.circle.fill")
            } else {
                Label("Up to date (latest is \(latest))", systemImage: "checkmark.circle.fill")
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
