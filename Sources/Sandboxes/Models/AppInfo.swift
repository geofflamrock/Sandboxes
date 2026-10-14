import Foundation

/// Version details from Info.plist, which CI stamps for each build.
enum AppInfo {
    /// The marketing version, such as "1.2.0".
    static let version = string(for: "CFBundleShortVersionString") ?? "0.0.0"
    /// The build number. CI uses the workflow run number.
    static let build = string(for: "CFBundleVersion") ?? "0"
    /// What kind of non-release build this is, such as "PR #12", "main" or "Local".
    /// Release builds have no label.
    static let buildLabel = string(for: "SandboxesBuildLabel")

    /// The part of the About panel shown in parentheses after the version.
    static var aboutPanelBuild: String {
        [buildLabel, "Build \(build)"].compactMap { $0 }.joined(separator: " · ")
    }

    private static func string(for key: String) -> String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}
