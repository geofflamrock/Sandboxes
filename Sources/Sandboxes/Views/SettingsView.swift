import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage(SbxCLI.executablePathKey) private var customPath = ""
    @State private var resolvedPath: String?
    @State private var hasResolved = false
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
                TextField("sbx location", text: $customPath, prompt: Text("Automatic"))
                    .font(.body.monospaced())
                LabeledContent("Using") {
                    if !hasResolved {
                        ProgressView().controlSize(.small)
                    } else if let resolvedPath {
                        Text(resolvedPath)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    } else {
                        Label("sbx not found", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Command Line Tool")
            } footer: {
                Text("Leave empty to find sbx on your login shell's PATH.")
                    .foregroundStyle(.secondary)
            }

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
                    Group {
                        TextField("Pretend to be version", text: $pretendVersion, prompt: Text(AppInfo.version))
                        TextField("Repository", text: $updateRepository, prompt: Text(UpdateChecker.defaultRepository))
                        LabeledContent {
                            Button("Check Now") {
                                Task { await updates.check() }
                            }
                            .disabled(updates.status == .checking)
                        } label: {
                            UpdateStatusLabel(status: updates.status, update: updates.availableUpdate)
                        }
                    }
                    .disabled(!forcesUpdateChecks)
                    .onSubmit {
                        Task { await updates.check() }
                    }
                } header: {
                    Text("Update Testing")
                } footer: {
                    Text("Only in builds that aren't releases. Pretend to be an older version to see the update in the sidebar and menu bar.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowReader(kind: .settings))
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
        .task(id: customPath) {
            resolvedPath = await Task.detached { SbxCLI.executableURL()?.path }.value
            hasResolved = true
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

/// The result of the last update check, for Settings › Update Testing.
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
