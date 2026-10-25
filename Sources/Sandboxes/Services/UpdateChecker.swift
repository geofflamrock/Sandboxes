import Foundation
import Observation
import Sparkle

/// Checks for, downloads and installs new releases with Sparkle.
///
/// Sparkle reads `appcast.xml` from the latest GitHub release, which lists the
/// release's DMG and its EdDSA signature. It checks the download against the
/// public key in Info.plist (`SUPublicEDKey`), replaces the app and relaunches
/// it. Updates installed this way aren't quarantined, so only the first
/// download from GitHub needs approving in System Settings.
///
/// Scheduled checks don't open Sparkle's window. They set `availableUpdate`
/// for the sidebar and menu bar, and clicking that opens Sparkle's window.
///
/// Only release builds check, since other builds are labelled and aren't on
/// the release track. To try it out in another build, use Settings › Development,
/// which sets these defaults (they also work as launch arguments):
///
/// - `UpdateCheckForceEnabled YES` checks even though the build has a label.
/// - `UpdateCheckRepository owner/name` reads another repository's appcast.
///
/// Release builds ignore both. Every build shares one set of defaults, so a
/// value left over from testing would otherwise hide or fake an update, and
/// releases have no Development tab to clear it from.
///
/// Sparkle compares build numbers. CI builds are numbered after every release
/// before them, so only a local build (build 1) sees a release as an update.
@MainActor
@Observable
final class UpdateChecker: NSObject {
    struct Release: Equatable {
        /// The version to show, such as "1.2.0".
        let version: String
    }

    /// A release newer than the running app, once a scheduled check has found
    /// one, until the user installs, skips or dismisses it.
    private(set) var availableUpdate: Release?
    /// Whether Sparkle has started, which it only does in builds that check.
    private(set) var isRunning = false
    /// Whether Sparkle checks every few hours, which the user can turn off.
    private(set) var checksAutomatically = true

    /// Before Sparkle, whether to check was stored here. Read once, so turning
    /// checks off carries over, then removed.
    nonisolated static let legacyEnabledKey = "checksForUpdates"
    nonisolated static let forceEnabledKey = "UpdateCheckForceEnabled"
    nonisolated static let repositoryKey = "UpdateCheckRepository"
    nonisolated static let defaultRepository = "geofflamrock/Sandboxes"

    @ObservationIgnored
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self
    )

    /// Whether this build is one that checks: a release, or one forced to.
    /// Sparkle refuses to start without a public key, and shows an alert
    /// saying the app is misconfigured, so builds without one don't try.
    static var isSupported: Bool {
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard publicKey?.isEmpty == false else { return false }
        return AppInfo.buildLabel == nil || UserDefaults.standard.bool(forKey: forceEnabledKey)
    }

    /// Starts Sparkle, which checks straight away when it's due and then on
    /// the schedule in Info.plist (`SUScheduledCheckInterval`).
    func start() {
        guard Self.isSupported, !isRunning else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.legacyEnabledKey) as? Bool == false {
            controller.updater.automaticallyChecksForUpdates = false
        }
        defaults.removeObject(forKey: Self.legacyEnabledKey)
        controller.startUpdater()
        isRunning = true
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
    }

    func setChecksAutomatically(_ isOn: Bool) {
        controller.updater.automaticallyChecksForUpdates = isOn
        checksAutomatically = isOn
    }

    /// Opens Sparkle's window, which shows the update found, or checks first.
    func checkForUpdates() {
        guard isRunning else { return }
        controller.checkForUpdates(nil)
    }

    /// A non-empty value from Settings › Development, or nil in release builds.
    private static func developmentOverride(forKey key: String) -> String? {
        guard AppInfo.buildLabel != nil else { return nil }
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

extension UpdateChecker: SPUUpdaterDelegate {
    /// Another repository's appcast when one is set in Settings › Development,
    /// otherwise nil for `SUFeedURL` from Info.plist.
    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.developmentOverride(forKey: Self.repositoryKey).map {
            "https://github.com/\($0)/releases/latest/download/appcast.xml"
        }
    }
}

/// Gentle reminders: the app runs in the menu bar, so a scheduled check that
/// finds an update shows it in the sidebar and menu bar rather than opening a
/// window over whatever the user is doing.
extension UpdateChecker: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        availableUpdate = Release(version: update.displayVersionString)
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableUpdate = nil
    }
}
