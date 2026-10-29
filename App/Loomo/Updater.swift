import Sparkle
import SwiftUI

/// Automatic updates for the direct-download build, through Sparkle. The feed is appcast.xml on the latest GitHub
/// release (Info.plist SUFeedURL); updates are checked against the EdDSA key in SUPublicEDKey. The App Store build
/// is sandboxed and updated by the App Store, so it never starts the updater.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?

    static var isAvailable: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
            && !CommandLine.arguments.contains("-UITests")
            && !AppLocation.isDevelopmentBuild
    }

    func start() {
        guard Self.isAvailable, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater = AppUpdater.shared
    var body: some View {
        if AppUpdater.isAvailable {
            Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
        }
    }
}

struct UpdateSettings: View {
    @ObservedObject var updater = AppUpdater.shared
    @State private var automatic = AppUpdater.shared.automaticallyChecks

    var body: some View {
        if AppUpdater.isAvailable {
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $automatic)
                    .onChange(of: automatic) { updater.automaticallyChecks = automatic }
                CheckForUpdatesButton()
            }
        }
    }
}

/// After an update, says once what changed, with a link to that version's release notes.
enum WhatsNew {
    private static let key = "whatsNew.lastVersion"

    @MainActor
    static func showIfUpdated() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: key)
        defaults.set(current, forKey: key)
        // First launch ever: the setup assistant is the introduction, not release notes.
        guard let last, !current.isEmpty, last != current, !CommandLine.arguments.contains("-UITests") else { return }
        let alert = NSAlert()
        alert.messageText = "Loomo is updated to \(current)"
        alert.informativeText = "See what's new in this version, including fixes and new features."
        alert.addButton(withTitle: "See What's New")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://github.com/Anrew3/Loomo/releases/tag/v\(current)") {
            NSWorkspace.shared.open(url)
        }
    }
}
