import Foundation
import Observation

/// A version number such as `0.48.0` or `0.49.0-rc1`.
struct SbxVersion: Comparable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    /// The part after the dash, such as `rc1`, or nil for a release.
    let prerelease: String?

    /// The first version number in `text`, such as the output of `sbx version`.
    init?(in text: String) {
        guard let match = text.firstMatch(of: #/(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.]+))?/#),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = match.4.map(String.init)
    }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    /// A prerelease comes before the release with the same number.
    static func < (lhs: SbxVersion, rhs: SbxVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case let (lhs?, rhs?): return lhs.localizedStandardCompare(rhs) == .orderedAscending
        case (_?, nil): return true
        default: return false
        }
    }
}

/// Whether sbx is installed, which version, and whether there's a newer
/// release. The app only shows the commands to install or upgrade it; the
/// user runs them.
@MainActor
@Observable
final class SbxStatus {
    enum State {
        case checking
        case notInstalled
        case installed(Installation)
    }

    struct Installation {
        let path: String
        /// Nil when `sbx version` didn't print a version number we recognise,
        /// such as a nightly build.
        let version: SbxVersion?
        /// The Homebrew cask that installed it, such as `sbx` or `sbx@rc`, or
        /// nil when it was installed some other way.
        let cask: String?

        /// The command that upgrades it, when Homebrew installed it.
        var upgradeCommand: String? {
            cask.map { "brew upgrade docker/tap/\($0)" }
        }
    }

    struct Release {
        let version: SbxVersion
        let url: URL
    }

    static let installCommand = "brew install docker/tap/sbx"
    static let releasesURL = URL(string: "https://github.com/docker/sbx-releases/releases/latest")!

    private(set) var state: State = .checking
    /// The newest stable release on GitHub, or nil until it's been fetched or
    /// when it couldn't be.
    private(set) var latest: Release?

    @ObservationIgnored private var latestCheckedAt: Date?
    @ObservationIgnored private var isChecking = false

    /// Unauthenticated GitHub API calls are limited to 60 an hour.
    private static let latestCacheDuration: TimeInterval = 6 * 60 * 60
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/docker/sbx-releases/releases/latest")!

    var installation: Installation? {
        guard case let .installed(installation) = state else { return nil }
        return installation
    }

    /// A newer stable release than the installed version.
    var availableUpgrade: Release? {
        guard let installed = installation?.version, let latest, installed < latest.version
        else { return nil }
        return latest
    }

    /// Whether the user has something to do: install sbx or upgrade it.
    var needsAttention: Bool {
        if case .notInstalled = state { return true }
        return availableUpgrade != nil
    }

    /// Looks for sbx and its version again, and for the latest release when
    /// the last look is out of date. Returns true when sbx was just installed.
    @discardableResult
    func check() async -> Bool {
        guard !isChecking else { return false }
        isChecking = true
        defer { isChecking = false }

        async let latestRelease = fetchLatestIfNeeded()
        var wasMissing = false
        if case .notInstalled = state { wasMissing = true }
        let installation = await Task.detached { Self.findInstallation() }.value
        if let installation {
            let output = try? await SbxCLI.runChecked(["version"])
            state = .installed(Installation(
                path: installation.path,
                version: output.flatMap(SbxVersion.init(in:)),
                cask: installation.cask
            ))
        } else {
            state = .notInstalled
        }
        await latestRelease
        return wasMissing && installation != nil
    }

    private func fetchLatestIfNeeded() async {
        if let latestCheckedAt, Date().timeIntervalSince(latestCheckedAt) < Self.latestCacheDuration {
            return
        }
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Keep showing the last release we found if GitHub can't be reached.
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              let version = SbxVersion(in: release.tagName)
        else { return }
        latest = Release(version: version, url: release.htmlURL)
        latestCheckedAt = Date()
    }

    /// The sbx executable and, when it's a link into Homebrew's Caskroom, the
    /// cask it belongs to (`/opt/homebrew/Caskroom/<cask>/<version>/…`).
    nonisolated private static func findInstallation() -> (path: String, cask: String?)? {
        guard let url = SbxCLI.executableURL() else { return nil }
        let components = url.resolvingSymlinksInPath().pathComponents
        let cask = components.firstIndex(of: "Caskroom")
            .flatMap { components.indices.contains($0 + 1) ? components[$0 + 1] : nil }
        return (url.path, cask)
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
