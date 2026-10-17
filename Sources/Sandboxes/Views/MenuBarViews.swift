import SwiftUI
import AppKit

/// The menu bar item: the app icon's sandbox, with the number of requests
/// waiting for approval when there are any.
struct MenuBarLabel: View {
    @Environment(SandboxStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let count = store.approvals.count
        HStack(spacing: 4) {
            Image(nsImage: .menuBarSandbox)
            if count > 0 {
                Text(count.formatted())
            }
        }
        .accessibilityLabel(count == 0 ? "Sandboxes" : "Sandboxes, \(count.formatted()) waiting for approval")
        .onAppear {
            // The label is always shown, so the window can be reopened even
            // after it's closed.
            AppWindows.openMain = { openWindow(id: AppWindows.mainID) }
            AppWindows.openCreate = { openWindow(id: AppWindows.createID) }
        }
    }
}

struct MenuBarMenu: View {
    @Environment(SandboxStore.self) private var store
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

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
        if let update = updates.availableUpdate {
            Button("Download Sandboxes \(update.version)…") {
                openURL(update.url)
            }
            Divider()
        }
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
    /// The app icon's sandbox with the agent in it, drawn as a template image
    /// so the menu bar tints it. Shapes are in the app icon's 1024pt
    /// coordinates from scripts/generate-app-icon.py, with its layer offsets
    /// applied.
    static let menuBarSandbox: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The artwork spans x 182–842 and y 195–829 in the icon.
            let scale = 16.0 / 660
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: 1 + (x - 182) * scale, y: (size.height - 634 * scale) / 2 + (y - 195) * scale)
            }
            func polygon(_ points: [CGPoint]) -> CGPath {
                let path = CGMutablePath()
                path.addLines(between: points)
                path.closeSubpath()
                return path
            }
            func roundedRect(_ rect: CGRect, _ radius: Double) -> CGPath {
                CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            let headTop = point(387, 289), headBottom = point(637, 541)
            let head = CGRect(x: headTop.x, y: headTop.y, width: headBottom.x - headTop.x, height: headBottom.y - headTop.y)
            let headRadius = 78 * scale

            // The box: its rim and walls as one shape.
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(polygon([point(512, 355.2), point(842, 530.1), point(842, 654.1), point(512, 829), point(182, 654.1), point(182, 530.1)]))
            context.fillPath()

            // Cut out the inside of the rim, the edges between the rim and the
            // walls, and a gap around the head, since a template image only
            // has one colour.
            context.setBlendMode(.clear)
            context.addPath(polygon([point(512, 384.9), point(785.9, 530.1), point(512, 675.3), point(238.1, 530.1)]))
            context.fillPath()
            context.setLineWidth(1)
            context.setLineJoin(.round)
            context.move(to: point(182, 530.1))
            context.addLine(to: point(512, 705))
            context.addLine(to: point(842, 530.1))
            context.move(to: point(512, 705))
            context.addLine(to: point(512, 829))
            context.strokePath()
            context.addPath(roundedRect(head.insetBy(dx: -1, dy: -1), headRadius + 1))
            context.fillPath()

            // The agent: its head and antenna, with the eyes cut out.
            context.setBlendMode(.normal)
            context.addPath(roundedRect(head, headRadius))
            context.fillPath()
            let light = point(512, 219)
            context.fill(CGRect(x: light.x - 0.5, y: light.y, width: 1, height: head.minY - light.y))
            context.fillEllipse(in: CGRect(x: light.x - 1.3, y: light.y - 1.3, width: 2.6, height: 2.6))
            context.setBlendMode(.clear)
            for x in [474.0, 550.0] {
                let eye = point(x, 390)
                context.addPath(roundedRect(CGRect(x: eye.x - 0.6, y: eye.y - 1, width: 1.2, height: 2), 0.6))
            }
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
