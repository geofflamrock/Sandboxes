import SwiftUI

/// A response to a pending approval, waiting for the user to confirm it.
struct ApprovalResponse {
    enum Action {
        case approve(NetworkApproval.Option)
        case deny
    }

    let approval: NetworkApproval
    /// The sandbox that asked, if it's still in the list.
    let sandbox: Sandbox?
    let action: Action

    private var sandboxName: String {
        sandbox?.name ?? approval.sandbox ?? "the sandbox"
    }

    var question: String {
        switch action {
        case .approve: "Allow access to “\(approval.title)”?"
        case .deny: "Deny access to “\(approval.title)”?"
        }
    }

    var message: String {
        switch action {
        case .approve:
            "This adds a rule that lets “\(sandboxName)” or every sandbox reach \(approval.title). Approving for all sandboxes also dismisses other sandboxes' requests for \(approval.target.host)."
        case .deny:
            "This adds a rule that blocks \(approval.title) for “\(sandboxName)” or for every sandbox, and dismisses the request. Denying for all sandboxes also dismisses other sandboxes' requests for \(approval.target.host)."
        }
    }
}

struct NetworkApprovalRow: View {
    enum Action {
        case approve(NetworkApproval.Option)
        case deny
        case dismiss(NetworkApproval.Option)
    }

    let approval: NetworkApproval
    let respond: (Action) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            Text(approval.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail = approval.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Deny") { respond(.deny) }
            if let option = approval.approveOption {
                Button("Approve") { respond(.approve(option)) }
                    .buttonStyle(.borderedProminent)
            }
            if let option = approval.dismissOption {
                Button("Dismiss", systemImage: "xmark") { respond(.dismiss(option)) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Dismiss this request. The sandbox asks again the next time it tries to reach \(approval.title).")
            }
        }
        .help([approval.title, approval.detail].compactMap { $0 }.joined(separator: "\n"))
    }
}

extension View {
    /// Asks the user to confirm approving or denying a pending approval, then
    /// sends the response.
    func approvalResponseDialog(_ response: Binding<ApprovalResponse?>) -> some View {
        modifier(ApprovalResponseDialog(response: response))
    }
}

private struct ApprovalResponseDialog: ViewModifier {
    @Binding var response: ApprovalResponse?
    @Environment(SandboxStore.self) private var store

    func body(content: Content) -> some View {
        content.confirmationDialog(
            response?.question ?? "",
            isPresented: Binding(
                get: { response != nil },
                set: { if !$0 { response = nil } }
            ),
            presenting: response
        ) { response in
            switch response.action {
            case let .approve(option):
                Button("Approve for This Sandbox") {
                    Task { await store.respond(to: response.approval, with: option) }
                }
                Button("Approve for All Sandboxes") {
                    Task { await store.approveForAllSandboxes(response.approval) }
                }
            case .deny:
                if let sandbox = response.sandbox {
                    Button("Deny for This Sandbox", role: .destructive) {
                        Task { await store.deny(response.approval, in: sandbox) }
                    }
                }
                Button("Deny for All Sandboxes", role: .destructive) {
                    Task { await store.deny(response.approval, in: nil) }
                }
            }
        } message: { response in
            Text(response.message)
        }
    }
}
