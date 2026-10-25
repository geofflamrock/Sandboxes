import Foundation
import Observation

/// Checks GitHub for a newer release of the app.
///
/// Only release builds check, since other builds are labelled and aren't on
/// the release track. To try it out in another build, use Settings › Development
/// Settings, which sets these defaults (they also work as launch arguments):
///
/// - `UpdateCheckForceEnabled YES` checks even though the build has a label.
/// - `UpdateCheckCurrentVersion 0.0.1` pretends the app is that version.
/// - `UpdateCheckRepository owner/name` checks another repository's releases.
///
/// Release builds ignore all three. Every build shares one set of defaults,
/// so a value left over from testing would otherwise hide or fake an update,
/// and releases have no Development tab to clear it from.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable {
        let version: AppVersion
        /// The release's page on GitHub, which has the DMG to download.
        let url: URL
    }

    enum Status: Equatable {
        case notChecked
        case checking
        /// The latest release, whether or not it's newer.
        case checked(latest: AppVersion)
        case failed(String)
    }

    /// A release newer than the running app, once a check has found one.
    private(set) var availableUpdate: Release?
    private(set) var status = Status.notChecked

    nonisolated static let enabledKey = "checksForUpdates"
    nonisolated static let forceEnabledKey = "UpdateCheckForceEnabled"
    nonisolated static let currentVersionKey = "UpdateCheckCurrentVersion"
    nonisolated static let repositoryKey = "UpdateCheckRepository"
    nonisolated static let defaultRepository = "geofflamrock/Sandboxes"
    private static let interval = Duration.seconds(6 * 60 * 60)

    /// Whether this build is one that checks: a release, or one forced to.
    static var isSupported: Bool {
        AppInfo.buildLabel == nil || UserDefaults.standard.bool(forKey: forceEnabledKey)
    }

    /// Whether the user wants checks, which they can turn off in Settings.
    static var isEnabled: Bool {
        isSupported && (UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true)
    }

    /// The version to compare against: the app's own, unless overridden.
    private static var currentVersionString: String {
        developmentOverride(forKey: currentVersionKey) ?? AppInfo.version
    }

    private static var repository: String {
        developmentOverride(forKey: repositoryKey) ?? defaultRepository
    }

    /// A non-empty value from Settings › Development, or nil in release builds.
    private static func developmentOverride(forKey key: String) -> String? {
        guard AppInfo.buildLabel != nil else { return nil }
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// Checks now and then every few hours, until the calling task is cancelled.
    func checkPeriodically() async {
        while !Task.isCancelled {
            await check()
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// Looks up the latest release. Failures keep the last update found,
    /// since being offline shouldn't hide an update that was already found.
    func check() async {
        guard Self.isEnabled else {
            availableUpdate = nil
            status = .notChecked
            return
        }
        guard let current = AppVersion(Self.currentVersionString) else {
            status = .failed("“\(Self.currentVersionString)” isn't a version number.")
            return
        }
        status = .checking
        do {
            let latest = try await Self.latestRelease(in: Self.repository)
            availableUpdate = latest.version > current ? latest : nil
            status = .checked(latest: latest.version)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private struct CheckError: LocalizedError {
        let errorDescription: String?
    }

    /// The newest published release. GitHub leaves out drafts and pre-releases.
    private static func latestRelease(in repository: String) async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw CheckError(errorDescription: "“\(repository)” isn't a repository name.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Sandboxes/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            break
        case 404:
            throw CheckError(errorDescription: "\(repository) doesn't exist or has no releases.")
        case let code:
            throw CheckError(errorDescription: "GitHub responded with status \(code.map(String.init) ?? "unknown").")
        }

        struct Payload: Decodable {
            let tag_name: String
            let html_url: URL
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let version = AppVersion(payload.tag_name) else {
            throw CheckError(errorDescription: "The latest release's tag “\(payload.tag_name)” isn't a version number.")
        }
        return Release(version: version, url: payload.html_url)
    }
}
