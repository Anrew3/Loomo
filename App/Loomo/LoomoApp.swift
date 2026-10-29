import AppKit
import CrimpCore
import CrimpOutputs
import PartsClient
import SwiftUI

@main
struct LoomoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = LibraryStore.shared

    init() {
        // AI clients (crimp mcp) reach open harnesses through this local socket.
        LiveBridge.shared.start()
        // Parts search runs in the app with the user's own keys (Keychain).
        PartsCredentials.start()
        // iCloud Drive ▸ Loomo for new projects. (The autosave interval is set once launching finishes: touching
        // NSDocumentController here, before SwiftUI installs its own, crashes SwiftUI at launch.)
        CloudDocuments.prepare()
        // Launch with the welcome window, not the document Open panel or an empty document.
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        CrimpTips.configure()
        DiagnosticsCollector.shared.start()
        // Photos some distributors only give to browsers (Mouser) are fetched through a hidden web view.
        PartImageCache.shared.browserFetch = { url in await WebImageLoader.shared.data(for: url) }
    }

    var body: some Scene {
        DocumentGroup(newDocument: { HarnessDocument() }) { file in
            ContentView(doc: file.document)
                .environmentObject(library)
                .modifier(LiveRegistration(doc: file.document, url: file.fileURL))
                .frame(minWidth: 1180, minHeight: 720)
                .onAppear { RecentProject.note(file.fileURL) }
                .onChange(of: file.fileURL) { RecentProject.note(file.fileURL) }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CrimpCommands()
            InsertCommands()
            AppearanceCommands()
            SystemCommands()
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { NotificationCenter.default.post(name: .showShortcuts, object: nil) }
                    .keyboardShortcut("/", modifiers: .command)
                Button("Show Tips Again") {
                    UserDefaults.standard.set(true, forKey: "tips.resetOnLaunch")
                    let alert = NSAlert()
                    alert.messageText = "Tips will show again the next time Loomo opens."
                    alert.runModal()
                }
            }
        }

        DocumentGroup(newDocument: { SystemDocument() }) { file in
            SystemContentView(doc: file.document)
                .environmentObject(library)
                .frame(minWidth: 1180, minHeight: 720)
                .onAppear { RecentProject.note(file.fileURL) }
                .onChange(of: file.fileURL) { RecentProject.note(file.fileURL) }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)

        Window("Welcome to Loomo", id: "welcome") {
            WelcomeView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        // The setup assistant comes first on a new Mac; the welcome window after it.
        .defaultLaunchBehavior(SetupAssistant.completed && (UserDefaults.standard.object(forKey: "welcome.showAtLaunch") as? Bool ?? true) ? .presented : .suppressed)

        Window("Set Up Loomo", id: "setup") {
            SetupAssistant()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(SetupAssistant.completed ? .suppressed : .presented)

        Window("Diagnostic Reports", id: "diagnostics") {
            DiagnosticsView()
        }
        .defaultSize(width: 640, height: 420)

        Window("Parts Library", id: "library") {
            LibraryWindow()
                .environmentObject(library)
                .frame(minWidth: 900, minHeight: 560)
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])

        Settings {
            SettingsView()
        }
    }
}

/// Menu commands that act on the focused document window.
struct CrimpCommands: Commands {
    @FocusedObject var doc: HarnessDocument?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Diagnostic Reports") { openWindow(id: "diagnostics") }
        }
        CommandGroup(before: .windowList) {
            Button("Welcome to Loomo") { openWindow(id: "welcome") }
            Button("Set Up Loomo…") { openWindow(id: "setup") }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Divider()
        }
        // New projects go to iCloud Drive when that's on (CloudDocuments), so they save from the first edit.
        CommandGroup(replacing: .newItem) {
            NewDocumentButton(title: "New Harness", key: "n", modifiers: [.command], project: .harness(Harness()))
            Divider()
            NewDocumentButton(title: "New System Project", key: "n", modifiers: [.command, .shift], project: .system(SystemProject()))
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Harness Section") { doc?.copy() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(doc == nil)
            Button("Paste Harness Section") { doc?.paste() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(doc == nil)
        }
        CommandGroup(replacing: .importExport) {
            Menu("Import") {
                Button("Wire List (CSV)…") { doc?.importWireList() }
            }
            .disabled(doc == nil)
            Menu("Export") {
                Button("Drawing Set (PDF)…") { doc?.exportPDF() }.keyboardShortcut("e")
                Button("Formboard 1:1 (PDF)…") { doc?.exportFormboard() }
                Button("Manufacturing Workbook (Excel)…") { doc?.exportExcel() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("WireViz YAML…") { doc?.exportWireViz() }
            }
            .disabled(doc == nil)
        }
        CommandMenu("Harness") {
            Group {
            Button("Add Wire…") { doc?.requestWire() }.keyboardShortcut("w", modifiers: [.command, .option])
            Button("Assistant") { NotificationCenter.default.post(name: .toggleAssistant, object: doc) }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Menu("Add Covering") {
                ForEach(CoveringKind.allCases, id: \.self) { k in Button(k.title) { doc?.addCovering(k) } }
            }
            Divider()
            Button("Lay Out to Scale") {
                doc?.perform("Lay Out to Scale") { $0.layoutToScale(pointsPerMM: 0.5) }
            }
            Button("Renumber Connectors C1, C2, C3…") {
                doc?.perform("Renumber Connectors") { $0.renumberConnectors(prefix: "C") }
            }
            Divider()
            Button("Delete Selection") { doc?.deleteSelection() }.keyboardShortcut(.delete, modifiers: [.command])
            }
            .disabled(doc == nil)
            Divider()
            Button("Parts Library") { openWindow(id: "library") }
        }
    }
}

/// A File menu item that starts a new project, in iCloud Drive when that's on.
private struct NewDocumentButton: View {
    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let project: NewProject
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument

    var body: some View {
        Button(title) { NewProjectAction(openDocument: openDocument, newDocument: newDocument)(project) }
            .keyboardShortcut(key, modifiers: modifiers)
    }
}

/// Commands for the focused system project window.
struct SystemCommands: Commands {
    @FocusedObject var system: SystemDocument?

    var body: some Commands {
        CommandMenu("System") {
            Group {
                Button("Add Device") { system?.addDevice() }
                Menu("Add Harness") {
                    Button("New Empty Harness") { system?.addHarness(Harness(name: "New harness")) }
                    Button("Import .loomo File…") { system?.importHarness() }
                }
                Button("Auto-Mate by Name") { system?.autoMate() }
                Divider()
                Button("Export System Drawing Set (PDF)…") { system?.exportPDF() }
                Button("Export System Workbook (Excel)…") { system?.exportExcel() }
            }
            .disabled(system == nil)
        }
    }
}

/// The team/private part library, shared by every window and saved to Application Support.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()
    @Published var library: PartLibrary {
        didSet {
            // Date each edit for team-library sync (assigning here doesn't re-run didSet).
            if !applyingSynced { library = LibrarySync.stamp(library, comparedTo: oldValue) }
            do {
                try library.save()
                saveError = nil
            } catch {
                // Keep editing in memory, but say so: a silent failure would lose the whole library on quit.
                saveError = error.localizedDescription
            }
            if !applyingSynced { TeamLibrary.shared.scheduleSync() }
        }
    }
    private var applyingSynced = false
    /// Why the last save of the parts library failed, shown in the Parts Library window.
    @Published var saveError: String?

    private init() { library = PartLibrary.load() }

    /// Takes the merged library from a team-library sync as-is (its dates come from the other Macs).
    func applySynced(_ merged: PartLibrary) {
        applyingSynced = true
        library = merged
        applyingSynced = false
    }

    /// Keeps a local copy of a photo downloaded from the team library and returns where it is.
    func importSyncedPhoto(_ downloaded: URL) -> URL? {
        let dir = PartLibrary.photosDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(UUID().uuidString).\(downloaded.pathExtension.isEmpty ? "png" : downloaded.pathExtension)")
        do { try FileManager.default.copyItem(at: downloaded, to: dest) } catch { return nil }
        return dest
    }

    /// The photo to show for a part everywhere in the app: the library's custom photo first.
    func photoURL(for part: PartRef) -> URL? { library.photoURL(for: part) }

    /// Copies an image into the library's Photos folder and makes it the entry's photo.
    /// Each import gets a fresh file name so caches never show the old picture.
    func setCustomPhoto(from source: URL, for id: LibraryPart.ID) throws {
        guard let i = library.parts.firstIndex(where: { $0.id == id }) else { return }
        let dir = PartLibrary.photosDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let dest = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: dest)
        removeCustomPhotoFile(library.parts[i].customPhotoURL)
        library.parts[i].customPhotoURL = dest
    }

    func clearCustomPhoto(for id: LibraryPart.ID) {
        guard let i = library.parts.firstIndex(where: { $0.id == id }) else { return }
        removeCustomPhotoFile(library.parts[i].customPhotoURL)
        library.parts[i].customPhotoURL = nil
    }

    private func removeCustomPhotoFile(_ url: URL?) {
        guard let url, url.isFileURL, url.path.hasPrefix(PartLibrary.photosDirectory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Updates a library entry with what a placement or refresh confirmed: cavity count, rows, pitch, gender, photo.
    func learn(from part: PartRef, into entry: LibraryPart) {
        var e = entry
        var p = e.part
        p.positionCount = part.positionCount ?? p.positionCount
        p.rowCount = part.rowCount ?? p.rowCount
        p.pitchMM = part.pitchMM ?? p.pitchMM
        p.contactGender = part.contactGender ?? p.contactGender
        p.imageURL = p.imageURL ?? part.imageURL
        p.datasheetURL = p.datasheetURL ?? part.datasheetURL
        e.part = p
        if e.category == "connector", let n = part.positionCount, e.cavityCount != n {
            e.cavityCount = n
            if e.faceLayout?.cavities.count != n { e.faceLayout = nil }   // geometry was for the wrong count
        }
        if e != entry { library.upsert(e) }
    }
}

struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PartsService.customKey) private var backendURL = ""
    @AppStorage("defaultUnits") private var defaultUnits = UnitSystem.metric.rawValue
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @AppStorage("partsProvider") private var providerRaw = PartsProvider.auto.rawValue
    @State private var usage: [String: ProviderUsage] = [:]

    var body: some View {
        Form {
            Section("Parts sources") {
                Text("Loomo searches distributors with your own free API keys, kept in your Mac's Keychain. Without any, it searches your parts library and a small sample catalog.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(PartsCredentials.sources) { PartsSourceForm(source: $0).padding(.vertical, 4) }
                Picker("Preferred source", selection: $providerRaw) {
                    ForEach(PartsProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Button("Run Setup Again…") { openWindow(id: "setup") }
            }
            Section("Parts usage") {
                if usage.isEmpty {
                    Text("No parts sources set up yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(usage.keys.sorted(), id: \.self) { name in
                    let u = usage[name]!
                    LabeledContent(PartsProvider(rawValue: name)?.title ?? name) {
                        VStack(alignment: .trailing) {
                            Text("\(u.callsToday) today\(u.dailyLimit.map { " / \($0)" } ?? "") · \(u.callsThisMonth) this month\(u.monthlyLimit.map { " / \($0)" } ?? "")")
                            if let why = u.unavailable { Text(why).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
                Button("Refresh") { Task { await loadUsage() } }
            }
            Section("Advanced") {
                TextField("Self-hosted parts service (optional)", text: $backendURL, prompt: Text("Leave empty to use the built-in search"))
            }
            CloudDocumentsSettings()
            AIClientsSettings()
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { AppAppearance.apply() }
            }
            Section("New harnesses") {
                Picker("Units", selection: $defaultUnits) {
                    Text("Metric (mm)").tag(UnitSystem.metric.rawValue)
                    Text("Imperial (in)").tag(UnitSystem.imperial.rawValue)
                }
            }
            Section("iCloud settings") {
                SettingsSyncStatus()
            }
            Section("Team library (iCloud)") {
                TeamLibraryControls()
            }
            Section("Library") {
                LabeledContent("Location", value: PartLibrary.defaultURL.path)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([PartLibrary.defaultURL]) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .task { await loadUsage() }
    }

    private func loadUsage() async {
        usage = (try? await PartsService.client(backendURL).usage()) ?? [:]
    }
}
