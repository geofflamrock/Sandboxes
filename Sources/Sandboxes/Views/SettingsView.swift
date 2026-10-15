import SwiftUI

struct SettingsView: View {
    @AppStorage(SbxCLI.executablePathKey) private var customPath = ""
    @State private var resolvedPath: String?
    @State private var hasResolved = false
    @AppStorage(ApprovalNotifier.enabledKey) private var notifiesAboutApprovals = true

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
            } header: {
                Text("Notifications")
            } footer: {
                Text("Click the notification to review the request. Choose how notifications appear in System Settings › Notifications.")
                    .foregroundStyle(.secondary)
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
        .task(id: customPath) {
            resolvedPath = await Task.detached { SbxCLI.executableURL()?.path }.value
            hasResolved = true
        }
    }
}
