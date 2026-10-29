import AppKit
import Combine
import CrimpCore
import CrimpOutputs
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (see scripts/build-app.sh).
    static let loomoSystem = UTType(exportedAs: "com.loomo.system", conformingTo: .json)
}

enum SystemSelection: Hashable {
    case device(EntityID), harness(EntityID), mate(EntityID)
}

/// A system project: devices, harness instances and the mates between them.
///
/// Each harness instance is edited through its own `HarnessDocument` (so the whole harness editor works inside the
/// system window). Child edits flow up into `project`; system-level undo flows back down. Both kinds of change
/// register on the window's UndoManager, so one undo stack covers everything.
final class SystemDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.loomoSystem] }

    @Published var project: SystemProject {
        didSet {
            analysis = SystemAnalysis(project)
            if !restoring { recordChange(from: oldValue) }
            if !syncingUp { pushDownToHarnesses() }
        }
    }
    @Published private(set) var analysis: SystemAnalysis
    @Published var selection: SystemSelection?
    /// Pin key whose net is traced and highlighted on the diagram.
    @Published var tracePin: String?
    @Published private(set) var history = UndoHistory<SystemProject>()

    weak var undoManager: UndoManager? {
        didSet { for c in children.values { c.undoManager = undoManager } }
    }
    private var restoring = false
    private var syncingUp = false
    private var pendingActionName: String?
    private var children: [EntityID: HarnessDocument] = [:]
    private var subscriptions: [EntityID: AnyCancellable] = [:]

    init(project: SystemProject = SystemProject()) {
        self.project = project
        self.analysis = SystemAnalysis(project)
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        let p = try SystemProject.load(from: data)
        project = p
        analysis = SystemAnalysis(p)
    }

    func snapshot(contentType: UTType) throws -> SystemProject {
        history.closeGroup()
        return project
    }

    func fileWrapper(snapshot: SystemProject, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot.encoded())
    }

    // MARK: Embedded harness editors

    func harnessDocument(for id: EntityID) -> HarnessDocument? {
        if let c = children[id] { return c }
        guard let inst = project.instance(id) else { return nil }
        let child = HarnessDocument(harness: inst.harness)
        child.undoManager = undoManager
        subscriptions[id] = child.$harness.dropFirst().sink { [weak self] h in self?.syncUp(id, h) }
        children[id] = child
        return child
    }

    private func syncUp(_ id: EntityID, _ h: Harness) {
        guard let i = project.harnesses.firstIndex(where: { $0.id == id }), project.harnesses[i].harness != h else { return }
        syncingUp = true
        restoring = true          // the child already registered its own undo step
        project.harnesses[i].harness = h
        restoring = false
        syncingUp = false
    }

    private func pushDownToHarnesses() {
        for (id, child) in children {
            if let inst = project.instance(id) {
                if child.harness != inst.harness { child.load(inst.harness) }
            } else {
                children[id] = nil
                subscriptions[id] = nil
            }
        }
    }

    // MARK: Undo

    func perform(_ name: String, _ change: (inout SystemProject) -> Void) {
        var p = project
        change(&p)
        guard p != project else { return }
        pendingActionName = name
        project = p
        pendingActionName = nil
    }

    private func recordChange(from old: SystemProject) {
        guard old != project else { return }
        let name = pendingActionName
        if history.record(previous: old, name: name) {
            undoManager?.registerUndo(withTarget: self) { $0.performUndo() }
            undoManager?.setActionName(name ?? "Edit")
        }
    }

    private func performUndo() {
        guard let previous = history.undo(current: project) else { return }
        let name = history.redoName ?? "Edit"
        restore(previous)
        undoManager?.registerUndo(withTarget: self) { $0.performRedo() }
        undoManager?.setActionName(name)
    }

    private func performRedo() {
        guard let next = history.redo(current: project) else { return }
        let name = history.undoName ?? "Edit"
        restore(next)
        undoManager?.registerUndo(withTarget: self) { $0.performUndo() }
        undoManager?.setActionName(name)
    }

    private func restore(_ p: SystemProject) {
        restoring = true
        project = p
        restoring = false
    }

    // MARK: Editing

    func moveBlock(_ id: SystemBlockID, to p: Point2D) {
        switch id {
        case let .device(d): if let i = project.devices.firstIndex(where: { $0.id == d }) { project.devices[i].position = p }
        case let .harness(h): if let i = project.harnesses.firstIndex(where: { $0.id == h }) { project.harnesses[i].position = p }
        }
    }

    func blockOrigin(_ id: SystemBlockID) -> Point2D? {
        switch id {
        case let .device(d): project.device(d)?.position
        case let .harness(h): project.instance(h)?.position
        }
    }

    private var freePosition: Point2D {
        let b = SystemLayout(project).bounds
        return b.isNull ? Point2D(40, 40) : Point2D(40, b.maxY + 10)
    }

    func addDevice() {
        perform("Add Device") { p in
            let id = p.nextID(prefix: "DEV")
            var d = Device(id: id, name: "New device", position: freePosition)
            d.connectors = [DeviceConnector(id: "J1", name: "", gender: .male, pinCount: 4)]
            p.devices.append(d)
            selection = .device(id)
        }
    }

    func addHarness(_ h: Harness, name: String? = nil) {
        perform("Add Harness") { p in
            let id = p.nextID(prefix: "H")
            var h = h
            if let name { h.name = name }
            p.harnesses.append(HarnessInstance(id: id, harness: h, position: freePosition))
            selection = .harness(id)
        }
    }

    func duplicateHarness(_ id: EntityID) {
        guard let inst = project.instance(id) else { return }
        addHarness(inst.harness, name: inst.harness.name + " copy")
    }

    func addMate(_ a: ConnectorRef, _ b: ConnectorRef) {
        guard a != b else { return }
        perform("Mate \(a) ⇄ \(b)") { p in
            p.mates.removeAll { $0.involves(a) || $0.involves(b) }
            let id = p.nextID(prefix: "M")
            // Keep harness connectors on side A so pin maps read "harness pin → device pin".
            let (x, y): (ConnectorRef, ConnectorRef) = if case .device = a, case .harness = b { (b, a) } else { (a, b) }
            p.mates.append(Mate(id: id, a: x, b: y))
            selection = .mate(id)
        }
    }

    func deleteSelection() {
        guard let s = selection else { return }
        perform("Delete") { p in
            switch s {
            case let .device(id):
                p.devices.removeAll { $0.id == id }
                p.mates.removeAll { $0.a.owner == id || $0.b.owner == id }
            case let .harness(id):
                p.harnesses.removeAll { $0.id == id }
                p.mates.removeAll { $0.a.owner == id || $0.b.owner == id }
            case let .mate(id):
                p.mates.removeAll { $0.id == id }
            }
        }
        selection = nil
    }

    func autoMate() {
        var made = 0
        perform("Auto-Mate by Name") { made = $0.autoMateByName() }
        let alert = NSAlert()
        alert.messageText = made == 0 ? "No new mates" : "Made \(made) mate\(made == 1 ? "" : "s")"
        alert.informativeText = "Harness connectors are matched to unmated device connectors whose name or id equals the harness connector's name."
        alert.runModal()
    }

    // MARK: Files

    private func save(_ data: Data, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
    }

    func exportPDF(includeHarnesses: Bool = true) {
        save(SystemPDF.make(project, analysis: analysis, includeHarnessDrawings: includeHarnesses),
             name: "\(project.name) rev \(project.revision).pdf", type: .pdf)
    }

    func exportExcel() {
        save(analysis.workbook(for: project).data(), name: "\(project.name) rev \(project.revision).xlsx",
             type: UTType(filenameExtension: "xlsx") ?? .data)
    }

    func exportHarness(_ id: EntityID) {
        guard let h = project.instance(id)?.harness, let data = try? h.jsonData() else { return }
        save(data, name: "\(h.name).loomo", type: .loomoHarness)
    }

    func importHarness() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.loomoHarness, .json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { addHarness(try Harness.load(from: Data(contentsOf: url))) } catch { NSAlert(error: error).runModal() }
        }
    }

    func importPinList(device: EntityID, connector: EntityID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.message = "Choose a device pin list (ICD) with Pin and Signal columns."
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        // Reuse the harness pin-list importer on a scratch connector, then copy the pins across.
        var scratch = Harness()
        scratch.connectors = [Connector(id: "J", cavityCount: 1)]
        scratch.connectors[0].cavities = []
        _ = scratch.importPinList(csv: text, into: "J")
        let pins = scratch.connectors[0].cavities.map { DevicePin(label: $0.label, signal: $0.signal) }
        guard !pins.isEmpty else { return }
        perform("Import Pin List") { p in
            guard let d = p.devices.firstIndex(where: { $0.id == device }),
                  let c = p.devices[d].connectors.firstIndex(where: { $0.id == connector }) else { return }
            p.devices[d].connectors[c].pins = pins
        }
    }
}
