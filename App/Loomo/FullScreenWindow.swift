import AppKit
import SwiftUI

/// Opens project windows in full screen (Settings ▸ Windows). Only the first window of a launch needs it: once
/// Loomo is in a full-screen space, macOS opens later document windows full screen too.
enum FullScreenWindows {
    static let key = "window.openFullScreen"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

extension View {
    func opensFullScreen() -> some View { background(FullScreenAnchor()) }
}

private struct FullScreenAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Anchor() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Anchor: NSView {
        private var done = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !done, let window, FullScreenWindows.enabled, !CommandLine.arguments.contains("-UITests") else { return }
            done = true
            // After the window is on screen; toggling earlier is ignored.
            DispatchQueue.main.async {
                guard window.isVisible, !window.styleMask.contains(.fullScreen),
                      window.collectionBehavior.contains(.fullScreenPrimary) || window.styleMask.contains(.resizable) else { return }
                window.toggleFullScreen(nil)
            }
        }
    }
}
