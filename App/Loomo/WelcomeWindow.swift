import AppKit
import CrimpCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The window Loomo opens with, like Xcode's: start something new on the left, recent projects on the
/// right. Shown at launch unless turned off; Window ▸ Welcome to Loomo (⇧⌘1) brings it back.
struct WelcomeView: View {
    @AppStorage("welcome.showAtLaunch") private var showAtLaunch = true
    @Environment(\.newDocument) private var newDocument
    private var newProject: NewProjectAction { NewProjectAction(openDocument: openDocument, newDocument: newDocument) }
    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var recents: [RecentProject] = RecentProject.load()
    @State private var hovered: URL?
    @State private var error: String?

    var body: some View {
        HStack(spacing: 0) {
            start
                .frame(width: 360)
            Divider()
            recent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 820, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recents = RecentProject.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            recents = RecentProject.load()
        }
        // Like Xcode: once a project window opens (from here, Finder or Open Recent), the welcome window goes.
        .onReceive(NotificationCenter.default.publisher(for: .projectWindowOpened)) { _ in close() }
    }

    // MARK: Left: identity and new projects

    private var start: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            Text("Loomo").font(.largeTitle.weight(.semibold)).padding(.top, 10)
            Text("Version \(Bundle.main.version)").font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                action("New Harness", detail: "Start a harness drawing", icon: "plus.square") {
                    newProject(.harness(Harness()))
                    close()
                }
                action("New System Project", detail: "Devices and several harnesses", icon: "rectangle.connected.to.line.below") {
                    newProject(.system(SystemProject()))
                    close()
                }
                action("Open Existing Project…", detail: "A .loomo or .loomosys file", icon: "folder") { browse() }
                action("Try the Sample Harness", detail: "An engine sensor harness to explore", icon: "sparkles.rectangle.stack") {
                    openSample()
                }
            }
            .padding(.top, 26)
            .padding(.horizontal, 28)
            Spacer(minLength: 16)
            Toggle("Show this window when Loomo opens", isOn: $showAtLaunch)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
        }
    }

    private func action(_ title: String, detail: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 30)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("welcome.\(title)")
    }

    // MARK: Right: recent projects

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Projects").font(.headline)
                Spacer()
                if !recents.isEmpty {
                    Button("Clear") {
                        RecentProject.clear()
                        recents = []
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(.horizontal, 16)
            }
            if recents.isEmpty {
                ContentUnavailableView("No recent projects", systemImage: "clock",
                                       description: Text("Projects you open or save appear here."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(recents) { project in
                            row(project)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func row(_ p: RecentProject) -> some View {
        Button { open(p.url) } label: {
            HStack(spacing: 12) {
                RecentThumbnail(url: p.url)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.body.weight(.medium)).lineLimit(1)
                    Text(p.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let date = p.modified {
                    Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered == p.url ? Color.accentColor.opacity(0.15) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? p.url : (hovered == p.url ? nil : hovered) }
        .contextMenu {
            Button("Open") { open(p.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
        }
        .help(p.url.path)
    }

    // MARK: Actions

    private func open(_ url: URL) {
        Task {
            do {
                try await openDocument(at: url)
                close()
            } catch {
                self.error = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.loomoHarness, .loomoSystem]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    private func close() { dismissWindow(id: "welcome") }

    /// Opens the bundled sample as a new, untitled harness, so exploring it never changes the original.
    private func openSample() {
        guard let url = Bundle.main.url(forResource: "EngineSensorHarness", withExtension: "json"),
              let data = try? Data(contentsOf: url), let sample = try? Harness.load(from: data) else {
            error = "The sample harness couldn't be opened."
            return
        }
        // Untitled, even with iCloud on: exploring the sample shouldn't leave copies in iCloud Drive.
        newDocument { HarnessDocument(harness: sample) }
        close()
    }
}

/// A project from the system's recent-documents list.
struct RecentProject: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }
    var folder: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
    var modified: Date?

    private static let key = "recentProjects"
    /// Security-scoped bookmarks, so a sandboxed Loomo (the App Store build) can reopen a file the user chose
    /// earlier. Plain paths are kept too, for older lists.
    private static let bookmarksKey = "recentProjectBookmarks"

    /// Loomo's own list (most recent first), plus anything in the system's recent documents.
    /// The system list alone is unreliable while the app is ad-hoc signed, so the app keeps its own.
    @MainActor
    static func load() -> [RecentProject] {
        let marked = (UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []).compactMap(resolve)
        let own = (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        return (marked + own + NSDocumentController.shared.recentDocumentURLs + CloudDocuments.projects())
            .filter { ["loomo", "loomosys"].contains($0.pathExtension.lowercased()) && FileManager.default.fileExists(atPath: $0.path) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .prefix(20)
            .map { RecentProject(url: $0, modified: try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) }
    }

    /// The file a bookmark points to, with access granted for this session (needed inside the sandbox).
    private static func resolve(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale) else {
            return nil
        }
        // Held for the life of the app: the welcome window may open it at any time.
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    /// Records a project as just opened or saved.
    static func note(_ url: URL?) {
        guard let url, url.isFileURL else { return }
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(20)), forKey: key)
        if let mark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            var marks = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
            marks.removeAll { resolvePath($0) == url.standardizedFileURL.path }
            marks.insert(mark, at: 0)
            UserDefaults.standard.set(Array(marks.prefix(20)), forKey: bookmarksKey)
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Where a bookmark points, without asking for access.
    private static func resolvePath(_ data: Data) -> String? {
        var stale = false
        return (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], bookmarkDataIsStale: &stale))?
            .standardizedFileURL.path
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: bookmarksKey)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}

/// The project's Quick Look thumbnail (the harness drawing, from Loomo' own thumbnail extension).
private struct RecentThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white)
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(2)
            } else {
                Image(systemName: url.pathExtension == "loomosys" ? "rectangle.connected.to.line.below" : "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 58, height: 44)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.quaternary))
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 116, height: 88),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

extension Notification.Name {
    /// Posted when a harness or system project window appears; closes the welcome window.
    static let projectWindowOpened = Notification.Name("LoomoProjectWindowOpened")
}

extension Bundle {
    /// "0.4.0 (1)".
    var version: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
