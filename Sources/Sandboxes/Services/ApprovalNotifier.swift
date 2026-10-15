import AppKit
import UserNotifications

/// Posts a notification when a sandbox's network request starts waiting for
/// approval, and opens that sandbox when the user clicks the notification.
final class ApprovalNotifier: NSObject, UNUserNotificationCenterDelegate {
    @MainActor static let shared = ApprovalNotifier()

    nonisolated static let enabledKey = "notifiesAboutApprovals"
    nonisolated private static let categoryID = "networkApproval"
    nonisolated private static let reviewActionID = "review"
    nonisolated private static let sandboxKey = "sandbox"

    private let center = UNUserNotificationCenter.current()
    /// The requests in the last list, or nil before the first one. Requests
    /// already waiting when the app starts are on screen, so they don't notify.
    @MainActor private var knownIDs: Set<NetworkApproval.ID>?
    @MainActor private weak var store: SandboxStore?

    @MainActor static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Call before the app finishes launching, so a click that launches the
    /// app is delivered.
    @MainActor func register(_ store: SandboxStore) {
        self.store = store
        center.delegate = self
        let review = UNNotificationAction(identifier: Self.reviewActionID, title: "Review", options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.categoryID, actions: [review], intentIdentifiers: [])
        center.setNotificationCategories([category])
        if Self.isEnabled {
            requestAuthorization()
        }
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Notifies about requests that weren't in the last list, and withdraws
    /// notifications for requests that are no longer waiting.
    @MainActor func update(_ approvals: [NetworkApproval]) {
        let ids = Set(approvals.map(\.id))
        defer { self.knownIDs = ids }
        guard let knownIDs else { return }
        let answered = knownIDs.subtracting(ids)
        if !answered.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: Array(answered))
        }
        guard Self.isEnabled else { return }
        for approval in approvals where !knownIDs.contains(approval.id) {
            post(approval)
        }
    }

    private func post(_ approval: NetworkApproval) {
        let content = UNMutableNotificationContent()
        if let sandbox = approval.sandbox {
            content.title = "“\(sandbox)” Is Waiting for Approval"
            content.userInfo = [Self.sandboxKey: sandbox]
            content.threadIdentifier = sandbox
        } else {
            content.title = "A Sandbox Is Waiting for Approval"
        }
        content.body = ["Wants to reach \(approval.title)", approval.detail].compactMap { $0 }.joined(separator: "\n")
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        center.add(UNNotificationRequest(identifier: approval.id, content: content, trigger: nil))
    }

    @MainActor private func review(sandbox: String?) {
        store?.showApprovals(forSandbox: sandbox)
        MainWindow.show()
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sandbox = response.notification.request.content.userInfo[Self.sandboxKey] as? String
        let opens = response.actionIdentifier == Self.reviewActionID
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor in
            if opens {
                self.review(sandbox: sandbox)
            }
            completionHandler()
        }
    }

    /// Shows the banner while the app is open too, unless the window is
    /// already showing that sandbox's requests.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let sandbox = notification.request.content.userInfo[Self.sandboxKey] as? String
        Task { @MainActor in
            let isShowing = NSApp.isActive && sandbox != nil
                && self.store?.isWindowOpen == true && self.store?.selectedSandbox?.name == sandbox
            completionHandler(isShowing ? [] : [.banner, .list, .sound])
        }
    }
}
