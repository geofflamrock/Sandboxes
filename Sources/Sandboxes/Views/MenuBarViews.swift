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
    /// The app icon's sandbox, drawn as a template image so the menu bar
    /// tints it. Shapes are in the app icon's 1024pt coordinates from
    /// scripts/generate-app-icon.py.
    static let menuBarSandbox: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The artwork spans x 182–842 and y 275.1–748.9 in the icon.
            let scale = 16.0 / 660
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: 1 + (x - 182) * scale, y: (size.height - 473.8 * scale) / 2 + (y - 275.1) * scale)
            }
            func polygon(_ points: [CGPoint]) -> CGPath {
                let path = CGMutablePath()
                path.addLines(between: points)
                path.closeSubpath()
                return path
            }

            // The box: its rim and walls as one shape.
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(polygon([point(512, 275.1), point(842, 450), point(842, 574), point(512, 748.9), point(182, 574), point(182, 450)]))
            context.fillPath()

            // Cut out the inside of the rim, then fill the sand back in a
            // little smaller, so a gap separates it from the rim, since a
            // template image only has one colour.
            context.setBlendMode(.clear)
            context.addPath(polygon([point(512, 304.83), point(785.9, 450), point(512, 595.17), point(238.1, 450)]))
            context.fillPath()
            context.setBlendMode(.normal)
            context.addPath(polygon([point(512, 353.45), point(709.2, 458), point(512, 562.55), point(314.8, 458)]))
            context.fillPath()

            // Cut out the edges between the rim and the walls.
            context.setBlendMode(.clear)
            context.setLineWidth(1)
            context.setLineJoin(.round)
            context.move(to: point(182, 450))
            context.addLine(to: point(512, 624.9))
            context.addLine(to: point(842, 450))
            context.move(to: point(512, 624.9))
            context.addLine(to: point(512, 748.9))
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
