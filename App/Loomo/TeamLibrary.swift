import AppKit
import CloudKit
import CrimpCore
import CryptoKit
import Security
import SwiftUI

/// The team parts library: the local library kept in sync with a CloudKit zone that the owner can share with
/// teammates (standard iCloud sharing). Merging is CrimpCore.LibrarySync: newest change wins per part, and
/// deletions travel too. Custom part photos sync as CloudKit assets.
///
/// CloudKit needs the app signed with an Apple Developer team and the iCloud capability (CloudKit, container
/// iCloud.com.loomo.Loomo). Until then this reports what is missing and never touches CloudKit.
@MainActor
final class TeamLibrary: ObservableObject {
    static let shared = TeamLibrary()
    static let containerID = "iCloud.com.loomo.Loomo"
    private static let zoneName = "TeamLibrary"
    private static let recordType = "LibraryPart"

    enum Status: Equatable {
        case notConfigured
        case off
        case checking
        case signedOut
        case syncing
        case synced(Date)
        case failed(String)

        var text: String {
            switch self {
            case .notConfigured: "Needs iCloud: set your team and add the iCloud (CloudKit) capability in Xcode."
            case .off: "Off"
            case .checking: "Checking iCloud…"
            case .signedOut: "Sign in to iCloud in System Settings to use the team library."
            case .syncing: "Syncing…"
            case let .synced(d): "Synced \(d.formatted(date: .omitted, time: .shortened))"
            case let .failed(why): "Sync failed: \(why)"
            }
        }
    }

    @Published private(set) var status: Status
    /// True when this Mac uses a library someone else shared, rather than its own.
    @Published private(set) var usingSharedLibrary: Bool
    @AppStorage("teamLibrary.enabled") var enabled = false {
        didSet { enabled ? scheduleSync(after: 0) : (status = .off) }
    }

    private var pending: Task<Void, Never>?
    private var running = false
    /// Zone of a library shared with us: zone name and owner, stored once a share is accepted.
    @AppStorage("teamLibrary.sharedZone") private var sharedZoneRaw = ""

    private init() {
        status = Self.hasICloudEntitlement ? .off : .notConfigured
        usingSharedLibrary = !(UserDefaults.standard.string(forKey: "teamLibrary.sharedZone") ?? "").isEmpty
    }

    /// Whether the running app is signed with CloudKit; without it any CloudKit call would crash.
    static var hasICloudEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) else { return false }
        return (value as? [String])?.contains("CloudKit") ?? false
    }

    private var container: CKContainer { CKContainer(identifier: Self.containerID) }

    private var zoneID: CKRecordZone.ID {
        let parts = sharedZoneRaw.split(separator: "|").map(String.init)
        if parts.count == 2 { return CKRecordZone.ID(zoneName: parts[0], ownerName: parts[1]) }
        return CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private var database: CKDatabase { usingSharedLibrary ? container.sharedCloudDatabase : container.privateCloudDatabase }

    // MARK: Sync

    /// Syncs soon (debounced), e.g. after a local edit.
    func scheduleSync(after seconds: Double = 3) {
        guard enabled, Self.hasICloudEntitlement else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    func sync() async {
        guard enabled, Self.hasICloudEntitlement, !running else { return }
        running = true
        defer { running = false }
        status = .checking
        do {
            guard try await container.accountStatus() == .available else {
                status = .signedOut
                return
            }
            status = .syncing
            if !usingSharedLibrary { try await ensureZone() }
            let remote = try await fetchAll()
            let store = LibraryStore.shared
            let plan = LibrarySync.merge(local: store.library, remote: remote.map(\.item))
            var library = plan.library
            // Remote photos arrive as assets; keep a local copy and point the part at it.
            for r in remote where r.photo != nil {
                if let i = library.parts.firstIndex(where: { $0.id == r.item.id && $0.modifiedAt == r.item.modifiedAt }),
                   let url = r.photo { library.parts[i].customPhotoURL = store.importSyncedPhoto(url) }
            }
            if library != store.library { store.applySynced(library) }
            if !plan.upload.isEmpty { try await upload(plan.upload) }
            status = .synced(Date())
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func ensureZone() async throws {
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
    }

    private struct Fetched { var item: LibrarySync.Item; var photo: URL? }

    private func fetchAll() async throws -> [Fetched] {
        var out: [Fetched] = []
        var token: CKServerChangeToken?
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (_, result) in changes.modificationResultsByID {
                guard let record = try? result.get().record, record.recordType == Self.recordType,
                      let id = record["partID"] as? String, let date = record["modifiedAt"] as? Date else { continue }
                let deleted = (record["deleted"] as? Int64 ?? 0) != 0
                let part = deleted ? nil : (record["json"] as? Data).flatMap { try? JSONDecoder().decode(LibraryPart.self, from: $0) }
                out.append(Fetched(item: LibrarySync.Item(id: id, modifiedAt: date, part: part),
                                   photo: (record["photo"] as? CKAsset)?.fileURL))
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        return out
    }

    private func upload(_ items: [LibrarySync.Item]) async throws {
        let records = items.map { item -> CKRecord in
            let record = CKRecord(recordType: Self.recordType, recordID: Self.recordID(for: item.id, zone: zoneID))
            record["partID"] = item.id
            record["modifiedAt"] = item.modifiedAt
            record["deleted"] = item.part == nil ? Int64(1) : Int64(0)
            if let part = item.part {
                record["json"] = try? JSONEncoder().encode(part)
                if let photo = part.customPhotoURL, photo.isFileURL, FileManager.default.fileExists(atPath: photo.path) {
                    record["photo"] = CKAsset(fileURL: photo)
                }
            }
            return record
        }
        // Newest-wins was decided locally, so overwrite whatever the server has.
        for batch in stride(from: 0, to: records.count, by: 200).map({ Array(records[$0..<min($0 + 200, records.count)]) }) {
            _ = try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .allKeys)
        }
    }

    /// Record names must be short and plain; part ids contain "|" and spaces.
    private static func recordID(for partID: String, zone: CKRecordZone.ID) -> CKRecord.ID {
        let hash = SHA256.hash(data: Data(partID.utf8)).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "part-" + hash.prefix(40), zoneID: zone)
    }

    // MARK: Sharing

    /// Opens the standard iCloud sharing sheet for this Mac's library zone.
    func share() {
        guard Self.hasICloudEntitlement, !usingSharedLibrary else { return }
        let container = self.container
        let zoneID = self.zoneID
        let provider = NSItemProvider()
        provider.registerCKShare(container: container, allowedSharingOptions: .standard) {
            let share = CKShare(recordZoneID: zoneID)
            share[CKShare.SystemFieldKey.title] = "Loomo Team Library"
            _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            _ = try await container.privateCloudDatabase.modifyRecords(saving: [share], deleting: [])
            return share
        }
        NSSharingService(named: .cloudSharing)?.perform(withItems: [provider])
    }

    /// Called when the user opens a share link for someone's team library.
    func accept(_ metadata: CKShare.Metadata) async {
        do {
            _ = try await CKContainer(identifier: metadata.containerIdentifier).accept(metadata)
            let zone = metadata.share.recordID.zoneID
            sharedZoneRaw = "\(zone.zoneName)|\(zone.ownerName)"
            usingSharedLibrary = true
            enabled = true
            await sync()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Goes back to this Mac's own library zone.
    func leaveSharedLibrary() {
        sharedZoneRaw = ""
        usingSharedLibrary = false
        scheduleSync(after: 0)
    }
}

/// Receives accepted iCloud share links.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { await TeamLibrary.shared.accept(metadata) }
    }

    /// The welcome window replaces the empty document a document app would open at launch.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window appears, so nothing flashes in the wrong appearance.
        MainActor.assumeIsolated { AppAppearance.apply() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Autosave at least every 30 s while editing (documents also save on switching windows and quitting).
        // Only now: SwiftUI's document controller exists by the time launching finishes.
        NSDocumentController.shared.autosavingDelay = 30
        Task { @MainActor in
            SettingsSync.shared.start()
            // Run from the disk image or Downloads: offer to move into Applications first.
            AppLocation.offerMove()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        TeamLibrary.shared.scheduleSync(after: 1)
    }
}

/// Team-library status and controls, shown in Settings and the Parts Library window.
struct TeamLibraryControls: View {
    @ObservedObject var team = TeamLibrary.shared

    var body: some View {
        if TeamLibrary.hasICloudEntitlement {
            Toggle("Sync the parts library with iCloud", isOn: $team.enabled)
            LabeledContent("Status", value: team.status.text)
            HStack {
                Button("Sync Now") { Task { await team.sync() } }.disabled(!team.enabled)
                if team.usingSharedLibrary {
                    Button("Use My Own Library") { team.leaveSharedLibrary() }
                } else {
                    Button("Share with Team…") { team.share() }.disabled(!team.enabled)
                }
            }
            Text(team.usingSharedLibrary ? "This Mac uses a library a teammate shared with you."
                                         : "Parts, settings and custom photos sync between your Macs; share to give teammates the same library.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label(TeamLibrary.Status.notConfigured.text, systemImage: "icloud.slash")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
