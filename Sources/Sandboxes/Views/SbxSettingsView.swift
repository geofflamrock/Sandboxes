import SwiftUI

/// The tabs of Settings. The selection is kept in user defaults so the Help
/// menu and the home page can open Settings at the sbx tab.
enum SettingsTab: String {
    case general
    case sbx

    static let key = "settingsTab"

    /// Opens Settings at `tab`, or brings it forward and switches to it.
    @MainActor
    static func show(_ tab: SettingsTab, _ openSettings: OpenSettingsAction) {
        UserDefaults.standard.set(tab.rawValue, forKey: key)
        AppWindows.showSettings(openSettings)
    }
}

/// Settings › sbx: where sbx is, which version it is, and the results of
/// `sbx diagnose`. What the user needs to do about them is on the home page.
struct SbxSettingsView: View {
    @AppStorage(SbxCLI.executablePathKey) private var customPath = ""
    @State private var resolvedPath: String?
    @State private var hasResolved = false
    @Environment(SbxStatus.self) private var sbxStatus

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
                LabeledContent("Version") {
                    SbxStatusValue(color: version.color, text: version.text)
                }
            } header: {
                Text("Command Line Tool")
            } footer: {
                Text("Leave empty to find sbx on your login shell's PATH.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button("Run Again") {
                        Task { await sbxStatus.diagnose() }
                    }
                    .disabled(sbxStatus.isDiagnosing || sbxStatus.installation == nil)
                    .help("Run sbx diagnose again")
                } label: {
                    HStack(spacing: 6) {
                        if sbxStatus.isDiagnosing {
                            ProgressView().controlSize(.small)
                        } else if let color = summaryColor {
                            StatusDot(color: color)
                        }
                        Text(summaryText)
                    }
                }
                if let diagnostics = sbxStatus.diagnostics {
                    ForEach(diagnostics.checks) { check in
                        SbxCheckRow(check: check)
                    }
                } else if let error = sbxStatus.diagnosticsError {
                    LabeledContent {
                        SbxStatusValue(color: .red, text: "Failed")
                    } label: {
                        Text("sbx diagnose")
                        Text(error)
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Checks from sbx diagnose.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .task(id: customPath) {
            resolvedPath = await Task.detached { SbxCLI.executableURL()?.path }.value
            hasResolved = true
            // A new location may be a different sbx, or one that works.
            await sbxStatus.check()
        }
    }

    private var version: (color: Color, text: String) {
        switch sbxStatus.state {
        case .checking:
            return (.secondary, "Checking…")
        case .notInstalled:
            return (.red, "Not installed")
        case let .installed(installation):
            guard let installed = installation.version else {
                return (.orange, "Unknown")
            }
            if let upgrade = sbxStatus.availableUpgrade {
                return (.orange, "\(installed) · \(upgrade.version) available")
            }
            return (.green, sbxStatus.latest == nil ? "\(installed)" : "\(installed) · Up to date")
        }
    }

    private var summaryColor: Color? {
        guard let diagnostics = sbxStatus.diagnostics else {
            return sbxStatus.diagnosticsError == nil ? nil : .red
        }
        if diagnostics.count(.fail) > 0 { return .red }
        if diagnostics.count(.warn) > 0 { return .orange }
        return .green
    }

    /// Such as "All 14 checks passed" or "1 failed · 2 warnings · 10 passed".
    private var summaryText: String {
        guard let diagnostics = sbxStatus.diagnostics else {
            if sbxStatus.installation == nil { return "sbx isn't installed" }
            if sbxStatus.diagnosticsError != nil { return "Couldn't run sbx diagnose" }
            return sbxStatus.isDiagnosing ? "Running…" : "Not run yet"
        }
        let failed = diagnostics.count(.fail)
        let warned = diagnostics.count(.warn)
        let passed = diagnostics.count(.pass)
        if failed == 0 && warned == 0 && passed == diagnostics.checks.count {
            return "All \(passed.formatted()) checks passed"
        }
        var parts: [String] = []
        if failed > 0 { parts.append("\(failed.formatted()) failed") }
        if warned > 0 { parts.append(warned == 1 ? "1 warning" : "\(warned.formatted()) warnings") }
        if passed > 0 { parts.append("\(passed.formatted()) passed") }
        let skipped = diagnostics.count(.skip)
        if skipped > 0 { parts.append("\(skipped.formatted()) skipped") }
        return parts.joined(separator: " · ")
    }
}

/// One `sbx diagnose` check: its name with the detail underneath, and a status
/// dot with its result on the right. Warnings and failures also say what to do.
private struct SbxCheckRow: View {
    let check: SbxDiagnostics.Check

    var body: some View {
        LabeledContent {
            SbxStatusValue(color: color, text: check.message.isEmpty ? check.status.displayName : check.message)
        } label: {
            Text(check.name)
            if !check.detail.isEmpty {
                Text(check.detail)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if !check.hint.isEmpty && (check.status == .fail || check.status == .warn) {
                Text(check.hint)
                    .textSelection(.enabled)
            }
        }
    }

    /// Green for passed, orange for a warning, red for failed and grey for
    /// skipped.
    private var color: Color {
        switch check.status {
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        case .skip: .secondary
        }
    }
}

/// A status dot and value, for the right side of a row.
private struct SbxStatusValue: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color)
            Text(text)
                .lineLimit(1)
        }
    }
}

private extension SbxDiagnostics.Check.Status {
    var displayName: String {
        switch self {
        case .pass: "Passed"
        case .warn: "Warning"
        case .fail: "Failed"
        case .skip: "Skipped"
        }
    }
}
