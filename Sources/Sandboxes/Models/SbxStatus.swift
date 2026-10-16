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

/// Whether sbx is installed, which version, whether there's a newer release,
/// and the results of `sbx diagnose`, with what the user needs to do about
/// them: install or upgrade sbx, start the daemon, or sign in.
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
        var upgrade: SbxCommandRun.Kind? {
            cask.map { .upgrade(cask: $0) }
        }
    }

    struct Release {
        let version: SbxVersion
        let url: URL
    }

    /// Something the user needs to do before, or to keep, sandboxes working.
    enum Action: Identifiable {
        case install
        case upgrade(Installation, to: Release)
        /// Start the daemon or sign in, found by `check`.
        case fix(SbxCommandRun.Kind, check: SbxDiagnostics.Check)

        var id: String {
            switch self {
            case .install: "install"
            case .upgrade: "upgrade"
            case let .fix(_, check): "fix-\(check.id)"
            }
        }
    }

    static let releasesURL = URL(string: "https://github.com/docker/sbx-releases/releases/latest")!

    private(set) var state: State = .checking
    /// The newest stable release on GitHub, or nil until it's been fetched or
    /// when it couldn't be.
    private(set) var latest: Release?
    /// The last results of `sbx diagnose`, kept while it runs again.
    private(set) var diagnostics: SbxDiagnostics?
    /// Why `sbx diagnose` couldn't run last time, if it couldn't.
    private(set) var diagnosticsError: String?
    private(set) var isDiagnosing = false
    /// Where a command's sheet shows: the main window, from the home page,
    /// or Settings.
    enum CommandWindow {
        case main
        case settings
    }

    /// A command fixing the setup, shown in a sheet while it runs and after.
    var commandRun: SbxCommandRun?
    /// The window `commandRun` shows in.
    private(set) var commandRunWindow: CommandWindow = .main
    /// The newest release the user dismissed the upgrade card for. The card
    /// comes back when a newer one is released.
    private(set) var dismissedUpgrade: SbxVersion? = UserDefaults.standard
        .string(forKey: SbxStatus.dismissedUpgradeKey)
        .flatMap(SbxVersion.init(in:)) {
        didSet {
            UserDefaults.standard.set(dismissedUpgrade?.description, forKey: Self.dismissedUpgradeKey)
        }
    }

    nonisolated private static let dismissedUpgradeKey = "dismissedSbxUpgrade"

    @ObservationIgnored private var latestCheckedAt: Date?
    @ObservationIgnored private var diagnosedAt: Date?
    @ObservationIgnored private var isChecking = false

    /// `sbx diagnose` collects a diagnostics bundle from the daemon, so it
    /// isn't rerun every time the app becomes active.
    private static let diagnosticsCacheDuration: TimeInterval = 5 * 60

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

    /// What the user needs to do, most important first: install sbx, start
    /// the daemon or sign in, then upgrade.
    var actions: [Action] {
        switch state {
        case .checking:
            return []
        case .notInstalled:
            return [.install]
        case let .installed(installation):
            var actions: [Action] = diagnostics?.checks.compactMap { check in
                check.fix.map { .fix($0, check: check) }
            } ?? []
            if let availableUpgrade, !isDismissed(availableUpgrade) {
                actions.append(.upgrade(installation, to: availableUpgrade))
            }
            return actions
        }
    }

    /// Looks for sbx and its version again, and for the latest release and
    /// runs `sbx diagnose` when the last results are out of date. Returns true
    /// when sbx was just installed.
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

        if installation == nil {
            diagnostics = nil
            diagnosticsError = nil
        } else if wasMissing || !diagnosticsAreRecent {
            await diagnose()
        }
        return wasMissing && installation != nil
    }

    /// Hides the upgrade card until a release newer than `release` comes out.
    func dismissUpgrade(to release: Release) {
        dismissedUpgrade = release.version
    }

    private func isDismissed(_ release: Release) -> Bool {
        guard let dismissedUpgrade else { return false }
        return release.version <= dismissedUpgrade
    }

    /// Called when the sandboxes stop loading: runs `sbx diagnose` straight
    /// away, without waiting for the last results to go out of date, so the
    /// home page can say to start the daemon or sign in.
    func sandboxesFailedToLoad() async {
        switch state {
        case .checking:
            // Diagnoses once it has found sbx, if it hasn't recently.
            await check()
        case .notInstalled:
            break
        case .installed:
            await diagnose()
        }
    }

    /// Runs `kind` in the command sheet in `window`. If it works, looks for sbx again
    /// and runs `sbx diagnose`, then calls `onSuccess`.
    func run(_ kind: SbxCommandRun.Kind, in window: CommandWindow = .main, onSuccess: @escaping @MainActor () -> Void) {
        let run = SbxCommandRun(kind: kind)
        run.start { [weak self] in
            Task {
                guard let self else { return }
                self.diagnosedAt = nil
                await self.check()
                onSuccess()
            }
        }
        commandRunWindow = window
        commandRun = run
    }

    /// The command to show in a sheet in `window`, if there's one there.
    func commandRun(in window: CommandWindow) -> SbxCommandRun? {
        commandRunWindow == window ? commandRun : nil
    }

    /// Runs `sbx diagnose` now.
    func diagnose() async {
        guard !isDiagnosing else { return }
        isDiagnosing = true
        defer {
            isDiagnosing = false
            diagnosedAt = Date()
        }
        do {
            diagnostics = try await SbxDiagnostics.run()
            diagnosticsError = nil
        } catch {
            diagnostics = nil
            diagnosticsError = error.localizedDescription
        }
    }

    private var diagnosticsAreRecent: Bool {
        guard let diagnosedAt else { return false }
        return Date().timeIntervalSince(diagnosedAt) < Self.diagnosticsCacheDuration
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
