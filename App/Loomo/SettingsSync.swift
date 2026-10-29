import Foundation
import Security
import SwiftUI

/// Keeps Loomo preferences in the user's iCloud account (NSUbiquitousKeyValueStore), so the same
/// settings follow them to every Mac signed in to that account. Only preferences that make sense
/// everywhere are synced; per-Mac ones (like API keys, which stay in each Mac's Keychain) stay local.
///
/// Needs the app signed with the iCloud capability's "Key-value storage"; until then it stays off.
@MainActor
final class SettingsSync: ObservableObject {
    static let shared = SettingsSync()

    /// UserDefaults keys that follow the iCloud account.
    static let syncedKeys: [String] = [
        "appearance", "defaultUnits", "partsProvider",
        "newWire.size", "newWire.color", "newWire.stripe", "newWire.insulation",
        "exportPages", "pinoutShowsFace", "welcome.showAtLaunch",
        "charts.bom", "charts.cutList", "teamLibrary.enabled",
    ]

    @Published private(set) var lastSynced: Date?
    private var applyingRemote = false
    private var observers: [NSObjectProtocol] = []

    static var isAvailable: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.ubiquity-kvstore-identifier" as CFString, nil) != nil
    }

    func start() {
        guard Self.isAvailable, observers.isEmpty else { return }
        let store = NSUbiquitousKeyValueStore.default
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            Task { @MainActor in self?.pull(keys ?? Self.syncedKeys) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.push() }
        })
        store.synchronize()
        // On launch the account's values win; keys it doesn't have yet are uploaded from this Mac.
        pull(Self.syncedKeys)
        push()
    }

    /// Copies values from iCloud into this Mac's preferences.
    private func pull(_ keys: [String]) {
        let store = NSUbiquitousKeyValueStore.default, defaults = UserDefaults.standard
        applyingRemote = true
        defer { applyingRemote = false }
        for key in keys where Self.syncedKeys.contains(key) {
            if let value = store.object(forKey: key) { defaults.set(value, forKey: key) }
            if key == AppAppearance.key { AppAppearance.apply() }
        }
        lastSynced = Date()
    }

    /// Uploads local preferences that differ from iCloud.
    private func push() {
        guard !applyingRemote else { return }
        let store = NSUbiquitousKeyValueStore.default, defaults = UserDefaults.standard
        var changed = false
        for key in Self.syncedKeys {
            guard let local = defaults.object(forKey: key) else { continue }
            if let remote = store.object(forKey: key) as? NSObject, remote.isEqual(local) { continue }
            store.set(local, forKey: key)
            changed = true
        }
        if changed {
            store.synchronize()
            lastSynced = Date()
        }
    }
}

/// Settings ▸ iCloud: what syncs and whether it can.
struct SettingsSyncStatus: View {
    @ObservedObject var sync = SettingsSync.shared

    var body: some View {
        if SettingsSync.isAvailable {
            Label("Your settings sync with your iCloud account", systemImage: "checkmark.icloud")
            if let d = sync.lastSynced {
                LabeledContent("Last synced", value: d.formatted(date: .omitted, time: .shortened))
            }
            Text("Units, parts source, new-wire defaults, export pages and display choices follow you to every Mac. API keys stay in each Mac's Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("Needs iCloud: set your team and turn on the iCloud capability's Key-value storage in Xcode.", systemImage: "icloud.slash")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
