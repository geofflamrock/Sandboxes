import SwiftUI
import AppKit

/// The menu bar item: the app icon's box, with the number of requests waiting
/// for approval when there are any.
struct MenuBarLabel: View {
    @Environment(SandboxStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let count = store.approvals.count
        HStack(spacing: 4) {
            Image(nsImage: .menuBarBox)
            if count > 0 {
                Text(count.formatted())
            }
        }
        .accessibilityLabel(count == 0 ? "Sandboxes" : "Sandboxes, \(count.formatted()) waiting for approval")
        .onAppear {
            // The label is always shown, so the window can be reopened even
            // after it's closed.
            AppWindows.openMain = { openWindow(id: AppWindows.mainID) }
        }
    }
}

struct MenuBarMenu: View {
    @Environment(SandboxStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if store.approvals.isEmpty {
            Text("No Requests Waiting for Approval")
        } else {
            Section("Waiting for Approval") {
                ForEach(store.approvals) { approval in
                    Button("\(approval.sandbox ?? "Unknown Sandbox"): \(approval.title)") {
                        store.showApprovals(forSandbox: approval.sandbox)
                        AppWindows.showMain()
                    }
                }
            }
        }
        Divider()
        Button("Open Sandboxes") {
            AppWindows.showMain()
        }
        Button("Settings…") {
            AppWindows.showSettings(openSettings)
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Sandboxes") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

extension NSImage {
    /// The app icon's taped box, drawn as a template image so the menu bar
    /// tints it. Shapes are on the 120-unit grid in scripts/generate-app-icon.py.
    static let menuBarBox: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The box spans x 30–90 and y 22–88 on the grid.
            let scale = 16.0 / 66
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: (size.width - 60 * scale) / 2 + (x - 30) * scale, y: 1 + (y - 22) * scale)
            }
            func polygon(_ points: [CGPoint]) -> CGPath {
                let path = CGMutablePath()
                path.addLines(between: points)
                path.closeSubpath()
                return path
            }

            context.setFillColor(NSColor.black.cgColor)
            context.addPath(polygon([point(60, 22), point(90, 38), point(90, 72), point(60, 88), point(30, 72), point(30, 38)]))
            context.fillPath()

            // Cut out the edges between the faces and the tape across the lid,
            // since a template image only has one colour.
            context.setBlendMode(.clear)
            context.setLineWidth(1)
            context.setLineJoin(.round)
            context.move(to: point(30, 38))
            context.addLine(to: point(60, 54))
            context.addLine(to: point(90, 38))
            context.move(to: point(60, 54))
            context.addLine(to: point(60, 88))
            context.strokePath()
            context.addPath(polygon([point(41.4, 31.9), point(48.6, 28.1), point(78.6, 44.1), point(71.4, 47.9)]))
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
