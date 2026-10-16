import Foundation
import Observation

/// Checks GitHub for a newer release of the app.
///
/// Only release builds check, since other builds are labelled and aren't on
/// the release track. To try it out in another build, pass launch arguments
/// or set them with `defaults write com.geofflamrock.sandboxes <key> <value>`:
///
/// - `UpdateCheckForceEnabled YES` checks even though the build has a label.
/// - `UpdateCheckCurrentVersion 0.0.1` pretends the app is that version.
/// - `UpdateCheckRepository owner/name` checks another repository's releases.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable {
        let version: AppVersion
        /// The release's page on GitHub, which has the DMG to download.
        let url: URL
    }

    /// A release newer than the running app, once a check has found one.
    private(set) var availableUpdate: Release?

    nonisolated static let enabledKey = "checksForUpdates"
    nonisolated private static let forceEnabledKey = "UpdateCheckForceEnabled"
    nonisolated private static let currentVersionKey = "UpdateCheckCurrentVersion"
    nonisolated private static let repositoryKey = "UpdateCheckRepository"
    nonisolated private static let defaultRepository = "geofflamrock/Sandboxes"
    private static let interval = Duration.seconds(6 * 60 * 60)

    /// Whether this build is one that checks: a release, or one forced to.
    static var isSupported: Bool {
        AppInfo.buildLabel == nil || UserDefaults.standard.bool(forKey: forceEnabledKey)
    }

    /// Whether the user wants checks, which they can turn off in Settings.
    static var isEnabled: Bool {
        isSupported && (UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true)
    }

    private static var currentVersion: AppVersion? {
        AppVersion(UserDefaults.standard.string(forKey: currentVersionKey) ?? AppInfo.version)
    }

    private static var repository: String {
        let value = UserDefaults.standard.string(forKey: repositoryKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : defaultRepository
    }

    /// Checks now and then every few hours, until the calling task is cancelled.
    func checkPeriodically() async {
        while !Task.isCancelled {
            await check()
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// Looks up the latest release. Failures keep the last result, since
    /// being offline shouldn't hide an update that was already found.
    func check() async {
        guard Self.isEnabled else {
            availableUpdate = nil
            return
        }
        guard let current = Self.currentVersion,
              let latest = try? await Self.latestRelease(in: Self.repository)
        else { return }
        availableUpdate = latest.version > current ? latest : nil
    }

    /// The newest published release. GitHub leaves out drafts and pre-releases.
    private static func latestRelease(in repository: String) async throws -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Sandboxes/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        struct Payload: Decodable {
            let tag_name: String
            let html_url: URL
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let version = AppVersion(payload.tag_name) else { return nil }
        return Release(version: version, url: payload.html_url)
    }
}
