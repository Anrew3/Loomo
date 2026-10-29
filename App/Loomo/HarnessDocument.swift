import AppKit
import CrimpCore
import CrimpOutputs
import PartsClient
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (see scripts/build-app.sh).
    static let loomoHarness = UTType(exportedAs: "com.loomo.harness", conformingTo: .json)
}

enum Selection: Hashable {
    case node(EntityID), segment(EntityID), connector(EntityID), wire(EntityID), splice(EntityID), covering(EntityID)
    case cable(EntityID), twist(EntityID), label(EntityID), annotation(EntityID)

    var id: EntityID {
        switch self {
        case let .node(i), let .segment(i), let .connector(i), let .wire(i), let .splice(i), let .covering(i),
             let .cable(i), let .twist(i), let .label(i), let .annotation(i): i
        }
    }
}

/// One open harness. Edits go through `harness`; every change is recorded in a snapshot
/// history that is bridged to the window's UndoManager, so Edit ▸ Undo, dirty state and autosave all work natively.
final class HarnessDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.loomoHarness, .json] }
    static var writableContentTypes: [UTType] { [.loomoHarness] }

    @Published var harness: Harness {
        didSet {
            analysis = HarnessAnalysis(harness)
            if !restoring { recordChange(from: oldValue) }
        }
    }
    @Published private(set) var analysis: HarnessAnalysis
    @Published var selection: Selection?
    /// Extra selection for multi-item actions (canvas nodes, table rows).
    @Published var multiSelection: Set<EntityID> = []
    @Published private(set) var history = UndoHistory<Harness>()
    /// A pending "place a part here" request; shows the part search sheet.
    @Published var placement: Placement?
    /// A pending New Wire sheet.
    @Published var wireRequest: WireRequest?
    /// Connector whose face layout editor is open.
    @Published var faceEditor: FaceEditTarget?
    /// Connector picture being cropped.
    @Published var cropTarget: CropTarget?
    /// Pending pass-through wiring between two connectors.
    @Published var passThrough: PassThroughRequest?
    /// Pending "move every wire to another connector" request.
    @Published var remap: RemapRequest?
    /// Pointer position on the drawing (model coordinates), for inserts from menus and keys.
    var lastPointer: CGPoint?
    var fallbackInsertCount = 0

    weak var undoManager: UndoManager?
    private var restoring = false
    private var pendingActionName: String?

    init(harness: Harness = Harness()) {
        self.harness = harness
        self.analysis = HarnessAnalysis(harness)
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        let h = try Harness.load(from: data)
        harness = h
        analysis = HarnessAnalysis(h)
    }

    func snapshot(contentType: UTType) throws -> Harness {
        history.closeGroup()
        return harness
    }

    func fileWrapper(snapshot: Harness, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot.jsonData())
    }

    // MARK: Undo

    /// Makes one named, undoable change.
    func perform(_ name: String, _ change: (inout Harness) -> Void) {
        var h = harness
        change(&h)
        guard h != harness else { return }
        pendingActionName = name
        harness = h
        pendingActionName = nil
    }

    private func recordChange(from old: Harness) {
        guard old != harness else { return }
        let name = pendingActionName
        if history.record(previous: old, name: name) {
            undoManager?.registerUndo(withTarget: self) { $0.performUndo() }
            undoManager?.setActionName(name ?? "Edit")
        }
    }

    private func performUndo() {
        guard let previous = history.undo(current: harness) else { return }
        let name = history.redoName ?? "Edit"
        restore(previous)
        undoManager?.registerUndo(withTarget: self) { $0.performRedo() }
        undoManager?.setActionName(name)
    }

    private func performRedo() {
        guard let next = history.redo(current: harness) else { return }
        let name = history.undoName ?? "Edit"
        restore(next)
        undoManager?.registerUndo(withTarget: self) { $0.performUndo() }
        undoManager?.setActionName(name)
    }

    private func restore(_ h: Harness) {
        restoring = true
        harness = h
        restoring = false
        if let s = selection, !exists(s) { selection = nil }
    }

    /// Replaces the design without recording an undo step (the owning system project already recorded it).
    func load(_ h: Harness) {
        restore(h)
    }

    /// Undo several steps at once, from the history list.
    func undo(steps: Int) {
        for _ in 0..<steps where undoManager?.canUndo == true { undoManager?.undo() }
    }

    // MARK: Lookup

    func exists(_ s: Selection) -> Bool {
        let h = harness
        switch s {
        case let .node(i): return h.node(i) != nil
        case let .segment(i): return h.segment(i) != nil
        case let .connector(i): return h.connector(i) != nil
        case let .wire(i): return h.wire(i) != nil
        case let .splice(i): return h.splice(i) != nil
        case let .covering(i): return h.coverings.contains { $0.id == i }
        case let .cable(i): return h.cable(i) != nil
        case let .twist(i): return h.twists.contains { $0.id == i }
        case let .label(i): return h.labels.contains { $0.id == i }
        case let .annotation(i): return h.annotations.contains { $0.id == i }
        }
    }

    /// Selection for any id the rule checker or a table reports ("C1:3" selects C1).
    func selection(for subject: EntityID) -> Selection? {
        let id = subject.split(separator: ":").first.map(String.init) ?? subject
        let h = harness
        if h.connector(id) != nil { return .connector(id) }
        if h.wire(id) != nil { return .wire(id) }
        if h.splice(id) != nil { return .splice(id) }
        if h.cable(id) != nil { return .cable(id) }
        if h.twists.contains(where: { $0.id == id }) { return .twist(id) }
        if h.coverings.contains(where: { $0.id == id }) { return .covering(id) }
        if h.labels.contains(where: { $0.id == id }) { return .label(id) }
        if h.segment(id) != nil { return .segment(id) }
        if h.node(id) != nil { return selection(forNode: id) }
        return nil
    }

    func selection(forNode id: EntityID) -> Selection {
        if let c = harness.connectors.first(where: { $0.nodeID == id }) { return .connector(c.id) }
        if let s = harness.splices.first(where: { $0.nodeID == id }) { return .splice(s.id) }
        return .node(id)
    }

    func binding<T: Identifiable>(_ kp: WritableKeyPath<Harness, [T]>, _ id: T.ID) -> Binding<T>? {
        guard let cached = harness[keyPath: kp].first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.harness[keyPath: kp].first { $0.id == id } ?? cached },
            set: { value in
                guard let i = self.harness[keyPath: kp].firstIndex(where: { $0.id == id }) else { return }
                self.harness[keyPath: kp][i] = value
            })
    }

    var allEndpoints: [Endpoint] {
        harness.connectors.flatMap { c in c.cavities.map { Endpoint.pin(connector: c.id, cavity: $0.label) } }
            + harness.splices.map { .splice($0.id) } + [.unassigned]
    }

    var units: UnitSystem { harness.settings.units }

    // MARK: Editing actions

    func moveNode(_ id: EntityID, to p: CGPoint) {
        guard let i = harness.nodes.firstIndex(where: { $0.id == id }) else { return }
        var p = p
        if harness.settings.snapToGrid {
            let g = max(harness.settings.gridSize, 1)
            p = CGPoint(x: (p.x / g).rounded() * g, y: (p.y / g).rounded() * g)
        }
        harness.nodes[i].position = Point2D(p.x, p.y)
    }

    func addNode(_ kind: NodeKind, at p: CGPoint, connectorKind: ConnectorKind = .housing) {
        perform("Add \(connectorKind == .housing ? kind.rawValue.capitalized : connectorKind.title)") { h in
            let nid = h.nextID(prefix: "N")
            var label = ""
            switch kind {
            case .connector:
                let cid = h.nextID(prefix: connectorKind.isLooseTerminal ? "T" : "C")
                h.connectors.append(Connector(id: cid, name: "", kind: connectorKind, nodeID: nid,
                                              cavityCount: connectorKind.isLooseTerminal ? 1 : 2))
                label = cid
                selection = .connector(cid)
            case .splice:
                let sid = h.nextID(prefix: "SP")
                h.splices.append(Splice(id: sid, nodeID: nid))
                label = sid
                selection = .splice(sid)
            case .breakout, .clip:
                label = h.nextID(prefix: kind == .clip ? "CL" : "BO")
                selection = .node(nid)
            }
            h.nodes.append(TopologyNode(id: nid, kind: kind, label: label, position: Point2D(p.x, p.y)))
        }
    }

    func addSegment(_ a: EntityID, _ b: EntityID) {
        guard a != b, !harness.segments.contains(where: { Set([$0.nodeA, $0.nodeB]) == Set([a, b]) }),
              let pa = harness.node(a)?.position, let pb = harness.node(b)?.position else { return }
        perform("Add Segment") { h in
            let length = max(10, (hypot(pa.x - pb.x, pa.y - pb.y) / 10).rounded() * 10)
            let id = h.nextID(prefix: "S")
            h.segments.append(Segment(id: id, nodeA: a, nodeB: b, lengthMM: length))
            selection = .segment(id)
        }
    }

    func addWire(from start: Endpoint = .unassigned) {
        perform("Add Wire") { h in
            let id = h.addWire(from: start)
            selection = .wire(id)
        }
    }

    /// Opens the New Wire sheet, optionally with one or both connectors chosen.
    func requestWire(from: EntityID? = nil, to: EntityID? = nil) {
        wireRequest = WireRequest(from: from, to: to)
    }

    func addCovering(_ kind: CoveringKind, segments: [EntityID]? = nil) {
        perform("Add Covering") { h in
            let id = h.nextID(prefix: "CV")
            var segs = segments ?? []
            if segments == nil, case let .segment(s)? = selection { segs = [s] }
            h.coverings.append(Covering(id: id, kind: kind, segmentIDs: segs, colorHex: kind == .tape ? "#5A6B7C" : "#222222"))
            selection = .covering(id)
        }
    }

    func addLabel(on segmentID: EntityID, offsetMM: Double) {
        perform("Add Label") { h in
            let id = h.nextID(prefix: "L")
            h.labels.append(BundleLabel(id: id, placement: .segment(segmentID, offsetMM: offsetMM)))
            selection = .label(id)
        }
    }

    func addAnnotation(_ kind: AnnotationKind, at p: CGPoint, image: Data? = nil) {
        perform("Add \(kind.rawValue.capitalized)") { h in
            let id = h.nextID(prefix: "A")
            let size: CGSize = switch kind {
            case .text: CGSize(width: 160, height: 20)
            case .arrow: CGSize(width: 80, height: -40)
            case .image: CGSize(width: 160, height: 120)
            case .sticky: CGSize(width: 170, height: 64)
            case .frame: CGSize(width: 420, height: 260)
            default: CGSize(width: 140, height: 70)
            }
            let text = switch kind {
            case .text: "Text"
            case .sticky: "Note"
            case .frame: "Sub-harness"
            default: ""
            }
            // Frames go behind the drawing so they never cover it.
            let z = kind == .frame ? (h.annotations.map(\.z).min() ?? 0) - 1 : (h.annotations.map(\.z).max() ?? 0) + 1
            h.annotations.append(Annotation(id: id, kind: kind, x: p.x, y: p.y, width: size.width, height: size.height,
                                            text: text, colorHex: kind == .frame ? "#2B3440" : "#000000", imagePNG: image, z: z))
            selection = .annotation(id)
        }
    }

    func deleteSelection() {
        guard let selection else { return }
        perform("Delete \(selection.id)") { h in
            func removeNode(_ nid: EntityID) {
                let segs = Set(h.segments.filter { $0.nodeA == nid || $0.nodeB == nid }.map(\.id))
                h.segments.removeAll { segs.contains($0.id) }
                for i in h.coverings.indices { h.coverings[i].segmentIDs.removeAll { segs.contains($0) } }
                h.labels.removeAll { if case let .segment(s, _) = $0.placement { return segs.contains(s) } else { return false } }
                h.nodes.removeAll { $0.id == nid }
            }
            func unassignEnds(at e: (Endpoint) -> Bool) {
                for i in h.wires.indices {
                    if e(h.wires[i].from) { h.wires[i].from = .unassigned }
                    if e(h.wires[i].to) { h.wires[i].to = .unassigned }
                }
            }
            switch selection {
            case let .node(id):
                removeNode(id)
            case let .segment(id):
                h.segments.removeAll { $0.id == id }
                for i in h.coverings.indices { h.coverings[i].segmentIDs.removeAll { $0 == id } }
            case let .connector(id):
                if let nid = h.connector(id)?.nodeID { removeNode(nid) }
                unassignEnds { $0.connectorID == id }
                h.connectors.removeAll { $0.id == id }
                h.labels.removeAll { $0.placement == .connector(id) }
            case let .wire(id):
                h.wires.removeAll { $0.id == id }
                h.untwist([id])
            case let .splice(id):
                if let nid = h.splice(id)?.nodeID { removeNode(nid) }
                unassignEnds { $0 == .splice(id) }
                h.splices.removeAll { $0.id == id }
            case let .covering(id):
                h.coverings.removeAll { $0.id == id }
            case let .cable(id):
                h.dissolveCable(id)
            case let .twist(id):
                h.twists.removeAll { $0.id == id }
            case let .label(id):
                h.labels.removeAll { $0.id == id }
            case let .annotation(id):
                h.annotations.removeAll { $0.id == id }
            }
        }
        self.selection = nil
    }

    // MARK: Placing parts and group edits

    struct Placement: Identifiable {
        /// A new component at a point (its kind comes from the part unless chosen), or a new part for a connector.
        enum Mode { case new(CGPoint), replacePart(EntityID) }
        let id = UUID()
        var mode: Mode

        var category: PartCategory {
            switch mode {
            case .new: .any
            case .replacePart: .connector
            }
        }

        var title: String {
            switch mode {
            case .new: "Place Component"
            case let .replacePart(id): "Change Part for \(id)"
            }
        }
    }

    func requestPlacement(at p: CGPoint) {
        placement = Placement(mode: .new(p))
    }

    /// Completes a placement with the chosen part (nil places a generic connector).
    @MainActor
    func completePlacement(_ placement: Placement, part: PartRef?, as chosenKind: ConnectorKind? = nil) {
        let config = part.flatMap { LibraryStore.shared.library.entry(for: $0) }
        // Keep the library honest: confirmed counts and distributor details flow back into the entry.
        if let part, let entry = config { LibraryStore.shared.learn(from: part, into: entry) }
        switch placement.mode {
        case let .new(p):
            // What the part is (fuse holder, relay, terminal, connector…) from its distributor data, unless chosen.
            let kind = chosenKind ?? ConnectorKind.detect(part, libraryCategory: config?.category)
            perform("Place \(part?.mpn ?? kind.title)") { h in
                let id = h.placeComponent(part: part, kind: kind, at: Point2D(p.x, p.y), configuration: config)
                selection = .connector(id)
                multiSelection = Set([h.connector(id)?.nodeID].compactMap { $0 })
            }
        case let .replacePart(cid):
            guard let part else { break }
            perform("Change \(cid) to \(part.mpn)") { h in
                guard let i = h.connectors.firstIndex(where: { $0.id == cid }) else { return }
                if let config {
                    let used = Set(h.wires.flatMap { [$0.from, $0.to] }.compactMap { e -> String? in
                        if case let .pin(c, cav) = e, c == cid { return cav }
                        return nil
                    })
                    h.connectors[i].apply(config, usedCavities: used)
                } else {
                    h.connectors[i].part = part
                    if h.connectors[i].kind.isLooseTerminal { h.connectors[i].cavities[0].terminal = part }
                    if let n = part.positionCount, n > h.connectors[i].cavities.count {
                        h.connectors[i].cavities += (h.connectors[i].cavities.count + 1...n).map { Cavity(label: String($0)) }
                    }
                }
            }
        }
        self.placement = nil
        if let url = part.flatMap(LibraryStore.shared.photoURL) {
            Task { @MainActor in
                _ = await PartImageCache.shared.image(for: url)
                self.objectWillChange.send()   // redraw with the photo
            }
        }
    }

    /// Everything currently selected on the drawing.
    var selectedIDs: Set<EntityID> {
        multiSelection.union(selection.map { [$0.id] } ?? [])
    }

    /// Number of distinct things selected (a connector and its node count once).
    var selectionCount: Int {
        let nodes = selectedNodeIDs
        let others = selectedIDs.filter { id in
            harness.node(id) == nil && !(harness.connector(id)?.nodeID.map(nodes.contains) ?? false)
                && !(harness.splice(id)?.nodeID.map(nodes.contains) ?? false)
        }
        return nodes.count + others.count
    }

    func deleteItems(_ ids: Set<EntityID>) {
        guard !ids.isEmpty else { return }
        perform(ids.count == 1 ? "Delete \(ids.first!)" : "Delete \(ids.count) Items") { $0.delete(ids) }
        selection = nil
        multiSelection = []
    }

    func selectAll() {
        multiSelection = Set(harness.nodes.map(\.id) + harness.annotations.map(\.id))
        selection = nil
    }

    /// Nodes in the current selection (connectors and splices map to their nodes).
    var selectedNodeIDs: Set<EntityID> {
        var ids = Set(selectedIDs.filter { harness.node($0) != nil })
        for id in selectedIDs {
            if let n = harness.connector(id)?.nodeID ?? harness.splice(id)?.nodeID { ids.insert(n) }
        }
        return ids
    }

    func duplicateSelection() {
        let nodes = selectedNodeIDs
        guard !nodes.isEmpty else { return }
        let clip = harness.copySection(nodeIDs: nodes)
        perform("Duplicate") { h in multiSelection = Set(h.paste(clip)) }
        selection = nil
    }

    func nudge(_ dx: Double, _ dy: Double) {
        let nodes = selectedNodeIDs
        let anns = Set(selectedIDs.filter { id in harness.annotations.contains { $0.id == id } })
        guard !nodes.isEmpty || !anns.isEmpty else { return }
        var origins: [EntityID: Point2D] = [:]
        for n in harness.nodes where nodes.contains(n.id) { origins[n.id] = n.position }
        for a in harness.annotations where anns.contains(a.id) { origins[a.id] = Point2D(a.x, a.y) }
        harness.move(nodes: nodes, annotations: anns, from: origins, by: dx, dy)
    }

    enum Alignment { case horizontal, vertical }

    func align(_ a: Alignment) {
        let nodes = harness.nodes.filter { selectedNodeIDs.contains($0.id) }
        guard nodes.count > 1 else { return }
        perform(a == .horizontal ? "Align Horizontally" : "Align Vertically") { h in
            let y = nodes.map(\.position.y).reduce(0, +) / Double(nodes.count)
            let x = nodes.map(\.position.x).reduce(0, +) / Double(nodes.count)
            for i in h.nodes.indices where nodes.contains(where: { $0.id == h.nodes[i].id }) {
                if a == .horizontal { h.nodes[i].position.y = y } else { h.nodes[i].position.x = x }
            }
        }
    }

    var canPaste: Bool {
        NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(HarnessClip.pasteboardType)) != nil
    }

    // MARK: Clipboard

    func copy() {
        var nodeIDs = selectedNodeIDs
        if nodeIDs.isEmpty, let s = selection {
            switch s {
            case let .connector(id): if let n = harness.connector(id)?.nodeID { nodeIDs = [n] }
            case let .splice(id): if let n = harness.splice(id)?.nodeID { nodeIDs = [n] }
            case let .node(id): nodeIDs = [id]
            default: break
            }
        }
        guard !nodeIDs.isEmpty, let data = try? JSONEncoder().encode(harness.copySection(nodeIDs: nodeIDs)) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: NSPasteboard.PasteboardType(HarnessClip.pasteboardType))
    }

    func paste() {
        guard let data = NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(HarnessClip.pasteboardType)),
              let clip = try? JSONDecoder().decode(HarnessClip.self, from: data) else { return }
        perform("Paste") { h in
            multiSelection = Set(h.paste(clip))
        }
    }

    // MARK: Part data

    /// Re-reads a connector's part from the distributors (photo, cavity count, rows, pitch, gender, price)
    /// and grows the connector if the part has more cavities than it does. Returns a summary.
    @MainActor
    func refreshPartData(connectorID: EntityID) async -> String {
        guard let c = harness.connector(connectorID), let part = c.part, !part.isGeneric else {
            return "This connector has no exact part number to look up."
        }
        do {
            // One merged answer from every source: photo from whichever has one, specs from the most structured.
            let response = try await PartsService.client().detail(mpn: part.mpn)
            guard let found = response.part, Harness.normalizedMPN(found.mpn) == Harness.normalizedMPN(part.mpn) else {
                return "No distributor result matched \(part.mpn)."
            }
            let fresh = found.partRef
            var summary: [String] = []
            perform("Refresh \(part.mpn)") { h in
                guard let i = h.connectors.firstIndex(where: { $0.id == connectorID }) else { return }
                var p = h.connectors[i].part ?? part
                // Credit each refreshed field to the source it came from; a description we keep stays credited as before.
                var credit = p.dataSources ?? [:]
                for (field, source) in fresh.dataSources ?? [:] where field != "description" || p.description == nil {
                    credit[field] = source
                }
                p.dataSources = credit.isEmpty ? nil : credit
                p.imageURL = fresh.imageURL ?? p.imageURL
                p.datasheetURL = fresh.datasheetURL ?? p.datasheetURL
                p.description = p.description ?? fresh.description
                p.unitPrice = fresh.unitPrice ?? p.unitPrice
                p.positionCount = fresh.positionCount ?? p.positionCount
                p.rowCount = fresh.rowCount ?? p.rowCount
                p.pitchMM = fresh.pitchMM ?? p.pitchMM
                p.contactGender = fresh.contactGender ?? p.contactGender
                h.connectors[i].part = p
                let have = h.connectors[i].cavities.count
                if let n = p.positionCount {
                    if n > have {
                        h.connectors[i].cavities += (have + 1...n).map { Cavity(label: String($0)) }
                        summary.append("Cavities: \(have) → \(n).")
                    } else if n < have {
                        summary.append("Distributors list \(n) positions but the connector has \(have) cavities; extra cavities were kept (they may hold wires).")
                    } else {
                        summary.append("Cavities: \(n) (unchanged).")
                    }
                } else {
                    summary.append("No cavity count in distributor data; set it from the datasheet.")
                }
                if let g = p.contactGender?.lowercased() { h.connectors[i].gender = g.hasPrefix("f") ? .female : .male }
                if let r = p.rowCount { summary.append("\(r) row\(r == 1 ? "" : "s")\(p.pitchMM.map { String(format: ", %g mm pitch", $0) } ?? "").") }
            }
            if let entry = LibraryStore.shared.library.entry(for: part), let updated = harness.connector(connectorID)?.part {
                LibraryStore.shared.learn(from: updated, into: entry)
            }
            return summary.joined(separator: "\n")
        } catch {
            return "Parts lookup failed: \(error.localizedDescription)"
        }
    }

    // MARK: Prices

    /// Fetches current prices for every purchasable MPN and writes them onto the design. Returns a summary.
    @MainActor
    func refreshPrices() async -> String {
        let mpns = harness.purchasableMPNs
        guard !mpns.isEmpty else { return "No exact part numbers to price yet (generic parts are skipped)." }
        do {
            let response = try await PartsService.client().offers(for: mpns)
            let prices = response.offers.compactMapValues(\.medianPrice)
            var changed = 0
            perform("Refresh Prices") { changed = $0.updatePrices(prices) }
            var summary = "Priced \(prices.count) of \(mpns.count) part numbers; \(changed) part references updated."
            if !response.missing.isEmpty { summary += "\nNo price found for: \(response.missing.prefix(12).joined(separator: ", "))." }
            if !response.errors.isEmpty { summary += "\n" + response.errors.joined(separator: "\n") }
            return summary
        } catch {
            return "Parts lookup failed: \(error.localizedDescription)"
        }
    }

    // MARK: Exports

    func save(_ data: Data, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
    }

    @MainActor
    func exportPDF(pages: [DrawingPage] = DrawingPage.allCases, sideTables: Bool = true) {
        save(PDFDrawingSet.make(harness, analysis: analysis, pages: pages, library: LibraryStore.shared.library, tablesOnDrawingSheet: sideTables),
             name: "\(harness.name) rev \(harness.revision).pdf", type: .pdf)
    }

    @MainActor
    func exportFormboard(_ options: FormboardOptions = FormboardOptions()) {
        let suffix = options.layout == .singleSheet ? "1-1 large format" : "1-1 \(options.paper.title)"
        save(Formboard.make(harness, options: options, library: LibraryStore.shared.library), name: "\(harness.name) formboard \(suffix).pdf", type: .pdf)
    }

    func exportExcel() {
        let type = UTType(filenameExtension: "xlsx") ?? .data
        save(analysis.workbook(for: harness).data(), name: "\(harness.name) rev \(harness.revision).xlsx", type: type)
    }

    func exportWireViz() {
        save(Data(WireVizExport.yaml(for: harness, analysis: analysis).utf8), name: "\(harness.name).yml",
             type: UTType(filenameExtension: "yml") ?? .plainText)
    }

    func importWireList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.message = "Choose a from-to wire list saved from Excel as CSV."
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var report = ImportReport()
        perform("Import Wire List") { h in report = h.importWireList(csv: text) }
        let alert = NSAlert()
        alert.messageText = "Imported \(report.wiresAdded) wires"
        var info = report.connectorsCreated.isEmpty ? "" : "Created connectors: \(report.connectorsCreated.joined(separator: ", ")).\n"
        info += report.connectorsCreated.isEmpty ? "" : "Place them on the topology canvas so lengths can be computed.\n"
        if !report.skippedRows.isEmpty { info += "Skipped: \(report.skippedRows.prefix(10).joined(separator: "; "))" }
        alert.informativeText = info
        alert.runModal()
    }

    func importPinList(into connectorID: EntityID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.message = "Choose a pin list (ICD) with Pin and Signal columns."
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        perform("Import Pin List") { _ = $0.importPinList(csv: text, into: connectorID) }
    }
}
