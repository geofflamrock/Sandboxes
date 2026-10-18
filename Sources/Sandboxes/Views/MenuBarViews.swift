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
    /// The app icon's sandbox with the agent peeking out of it, drawn as a
    /// template image so the menu bar tints it. Shapes are in the app icon's
    /// 1024pt coordinates from scripts/generate-app-icon.py.
    static let menuBarSandbox: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The artwork spans x 182–842 and y 236.55–787.45 in the icon.
            let scale = 16.0 / 660
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: 1 + (x - 182) * scale, y: (size.height - 550.9 * scale) / 2 + (y - 236.55) * scale)
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
            // The head: rounded at the top, with its bottom a shallow curve
            // where it disappears into the sand.
            let head = CGMutablePath()
            head.move(to: point(387, 486.55))
            head.addArc(tangent1End: point(387, 330.55), tangent2End: point(637, 330.55), radius: 78 * scale)
            head.addArc(tangent1End: point(637, 330.55), tangent2End: point(637, 486.55), radius: 78 * scale)
            head.addLine(to: point(637, 486.55))
            head.addQuadCurve(to: point(387, 486.55), control: point(512, 552.55))
            head.closeSubpath()

            // The box: its rim and walls as one shape.
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(polygon([point(512, 313.65), point(842, 488.55), point(842, 612.55), point(512, 787.45), point(182, 612.55), point(182, 488.55)]))
            context.fillPath()

            // Cut out the inside of the rim, then fill the sand back in a
            // little smaller, so a gap separates it from the rim, since a
            // template image only has one colour.
            context.setBlendMode(.clear)
            context.addPath(polygon([point(512, 343.38), point(785.9, 488.55), point(512, 633.72), point(238.1, 488.55)]))
            context.fillPath()
            context.setBlendMode(.normal)
            context.addPath(polygon([point(512, 392), point(709.2, 496.55), point(512, 601.1), point(314.8, 496.55)]))
            context.fillPath()

            // Cut out the edges between the rim and the walls, and a gap
            // around the head.
            context.setBlendMode(.clear)
            context.setLineWidth(1)
            context.setLineJoin(.round)
            context.move(to: point(182, 488.55))
            context.addLine(to: point(512, 663.45))
            context.addLine(to: point(842, 488.55))
            context.move(to: point(512, 663.45))
            context.addLine(to: point(512, 787.45))
            context.strokePath()
            context.setLineWidth(2)
            context.addPath(head)
            context.strokePath()

            // The agent: its head and antenna, with the eyes cut out.
            context.setBlendMode(.normal)
            context.addPath(head)
            context.fillPath()
            let light = point(512, 260.55), headTop = point(512, 330.55)
            context.fill(CGRect(x: light.x - 0.5, y: light.y, width: 1, height: headTop.y - light.y))
            context.fillEllipse(in: CGRect(x: light.x - 1.3, y: light.y - 1.3, width: 2.6, height: 2.6))
            context.setBlendMode(.clear)
            for x in [474.0, 550.0] {
                let eye = point(x, 431.55)
                context.addPath(roundedRect(CGRect(x: eye.x - 0.6, y: eye.y - 1, width: 1.2, height: 2), 0.6))
            }
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
