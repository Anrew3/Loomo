import AppKit
import SwiftUI

/// Light, dark, or follow the Mac. Applied to the whole app (all windows, menus, sheets and panels),
/// independent of the system setting, and synced with the user's other settings through iCloud.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static let key = "appearance"

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// Sets the app-wide appearance; nil follows the system.
    @MainActor
    static func apply(_ choice: AppAppearance = current) {
        switch choice {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// View ▸ Appearance.
struct AppearanceCommands: Commands {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: appearance) { AppAppearance.apply() }
            Divider()
        }
    }
}
