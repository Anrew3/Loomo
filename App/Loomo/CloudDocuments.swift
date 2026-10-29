import AppKit
import CrimpCore
import SwiftUI

/// Projects in the user's iCloud Drive, in a "Loomo" folder that appears in Finder on every Mac signed in to the
/// same Apple ID. New projects are created there and opened straight away, so autosave keeps them current from
/// the first edit, with no Save dialog. iCloud syncs the file; macOS keeps its version history (File ▸ Revert To).
///
/// Needs the iCloud Documents capability (container iCloud.com.loomo.Loomo) and the user signed in to iCloud.
/// Without either, new projects start as ordinary untitled documents, as before.
@MainActor
enum CloudDocuments {
    static let containerID = "iCloud.com.loomo.Loomo"
    static let enabledKey = "iCloud.newProjects"

    /// iCloud Drive ▸ Loomo, once the container has been looked up (`prepare()`), or nil when iCloud isn't available.
    private(set) static var folder: URL?

    /// Off during UI tests, so test runs don't fill the user's iCloud Drive with untitled harnesses.
    static var enabled: Bool {
        !ProcessInfo.processInfo.arguments.contains("-UITests") && (UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true)
    }

    /// Looks up the iCloud container. The first lookup can take a moment, so it runs off the main thread at launch.
    static func prepare() {
        Task.detached(priority: .utility) {
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else { return }
            // "Documents" inside the container is what Finder shows as iCloud Drive ▸ Loomo.
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            await MainActor.run { folder = documents }
        }
    }

    /// Writes a new project into iCloud Drive ▸ Loomo under a free name ("Untitled Harness 2"), or returns nil
    /// when new projects shouldn't or can't go to iCloud.
    static func create(_ data: Data, named base: String, extension ext: String) -> URL? {
        guard enabled, let folder else { return nil }
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        do {
            try data.write(to: url, options: .withoutOverwriting)
            return url
        } catch {
            return nil
        }
    }

    /// Projects in iCloud Drive ▸ Loomo, including ones made on other Macs (they download when opened).
    static func projects() -> [URL] {
        guard let folder,
              let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        return items.filter { ["loomo", "loomosys"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
    }

    static func showInFinder() {
        guard let folder else { return }
        NSWorkspace.shared.open(folder)
    }
}

/// The two kinds of new project, and how to write an empty (or sample) one to a file.
enum NewProject {
    case harness(Harness)
    case system(SystemProject)

    var baseName: String {
        switch self {
        case .harness: "Untitled Harness"
        case .system: "Untitled System"
        }
    }

    var fileExtension: String {
        switch self {
        case .harness: "loomo"
        case .system: "loomosys"
        }
    }

    var data: Data? {
        switch self {
        case let .harness(h): try? h.jsonData()
        case let .system(p): try? p.jsonData()
        }
    }
}

/// Starts a new project: in iCloud Drive when that's on and available, otherwise as an untitled document.
@MainActor
struct NewProjectAction {
    let openDocument: OpenDocumentAction
    let newDocument: NewDocumentAction

    func callAsFunction(_ project: NewProject) {
        if let data = project.data, let url = CloudDocuments.create(data, named: project.baseName, extension: project.fileExtension) {
            RecentProject.note(url)
            Task { try? await openDocument(at: url) }
            return
        }
        switch project {
        case let .harness(h): newDocument { HarnessDocument(harness: h) }
        case let .system(p): newDocument { SystemDocument(project: p) }
        }
    }
}

/// Settings ▸ iCloud Drive.
struct CloudDocumentsSettings: View {
    @AppStorage(CloudDocuments.enabledKey) private var enabled = true

    var body: some View {
        Section("iCloud Drive") {
            Toggle("Create new projects in iCloud Drive", isOn: $enabled)
            if CloudDocuments.folder != nil {
                Text("New projects go to iCloud Drive ▸ Loomo and save automatically, so they're on every Mac signed in to your Apple ID.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show in Finder") { CloudDocuments.showInFinder() }
            } else {
                Text("iCloud isn't available. Sign in to iCloud and turn on iCloud Drive in System Settings, then reopen Loomo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
