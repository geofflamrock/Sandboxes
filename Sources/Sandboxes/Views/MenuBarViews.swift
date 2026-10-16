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
            AppWindows.openCreateFromEnvironment = { openWindow(id: AppWindows.createFromEnvironmentID) }
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
    /// 1024pt coordinates from scripts/generate-app-icon.py, before it
    /// recentres the artwork, with the agent already grown by its AGENT_SCALE.
    static let menuBarSandbox: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The artwork spans x 182–842 and y 178.45–789.95 in the icon.
            let scale = 16.0 / 660
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: 1 + (x - 182) * scale, y: (size.height - 611.5 * scale) / 2 + (y - 178.45) * scale)
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
            head.move(to: point(362, 502.45))
            head.addArc(tangent1End: point(362, 291.25), tangent2End: point(662, 291.25), radius: 93.6 * scale)
            head.addArc(tangent1End: point(662, 291.25), tangent2End: point(662, 502.45), radius: 93.6 * scale)
            head.addLine(to: point(662, 502.45))
            head.addQuadCurve(to: point(362, 502.45), control: point(512, 581.65))
            head.closeSubpath()

            // The box: its rim and walls as one shape.
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(polygon([point(512, 316.15), point(842, 491.05), point(842, 615.05), point(512, 789.95), point(182, 615.05), point(182, 491.05)]))
            context.fillPath()

            // Cut out the inside of the rim, then fill the sand back in a
            // little smaller, so a gap separates it from the rim, since a
            // template image only has one colour.
            context.setBlendMode(.clear)
            context.addPath(polygon([point(512, 345.88), point(785.9, 491.05), point(512, 636.22), point(238.1, 491.05)]))
            context.fillPath()
            context.setBlendMode(.normal)
            context.addPath(polygon([point(512, 394.5), point(709.2, 499.05), point(512, 603.6), point(314.8, 499.05)]))
            context.fillPath()

            // Cut out the edges between the rim and the walls, and a gap
            // around the head.
            context.setBlendMode(.clear)
            context.setLineWidth(1)
            context.setLineJoin(.round)
            context.move(to: point(182, 491.05))
            context.addLine(to: point(512, 665.95))
            context.addLine(to: point(842, 491.05))
            context.move(to: point(512, 665.95))
            context.addLine(to: point(512, 789.95))
            context.strokePath()
            context.setLineWidth(2)
            context.addPath(head)
            context.strokePath()

            // The agent: its head and antenna, with the eyes cut out.
            context.setBlendMode(.normal)
            context.addPath(head)
            context.fillPath()
            let light = point(512, 207.25), headTop = point(512, 291.25)
            context.fill(CGRect(x: light.x - 0.6, y: light.y, width: 1.2, height: headTop.y - light.y))
            context.fillEllipse(in: CGRect(x: light.x - 1.55, y: light.y - 1.55, width: 3.1, height: 3.1))
            context.setBlendMode(.clear)
            for x in [466.4, 557.6] {
                let eye = point(x, 412.45)
                context.addPath(roundedRect(CGRect(x: eye.x - 0.7, y: eye.y - 1.2, width: 1.4, height: 2.4), 0.7))
            }
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
