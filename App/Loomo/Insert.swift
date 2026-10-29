import AppKit
import CrimpCore
import SwiftUI
import TipKit

/// Everything that can be added to a drawing. Right-click menus, the Insert menu and single-key shortcuts
/// all go through `HarnessDocument.insert`, so they behave the same wherever they are triggered.
enum InsertKind: String, CaseIterable, Identifiable {
    case connector, splice, breakout, clip, matedPair, wire, bundle, label, sticky, frame, text, arrow, box, image
    var id: String { rawValue }

    var title: String {
        switch self {
        case .connector: "Component…"
        case .splice: "Splice"
        case .breakout: "Breakout"
        case .clip: "Clip"
        case .matedPair: "In-Line Mated Pair…"
        case .wire: "Wire…"
        case .bundle: "Bundle Between Selected Nodes"
        case .label: "Bundle Label"
        case .sticky: "Sticky Note"
        case .frame: "Frame"
        case .text: "Text"
        case .arrow: "Arrow"
        case .box: "Box"
        case .image: "Image…"
        }
    }

    /// Key that triggers it when the drawing has focus (shown in menus as a hint).
    var key: Character {
        switch self {
        case .connector: "c"
        case .splice: "s"
        case .breakout: "j"
        case .clip: "k"
        case .matedPair: "m"
        case .wire: "w"
        case .bundle: "b"
        case .label: "l"
        case .sticky: "n"
        case .frame: "g"
        case .text: "t"
        case .arrow: "a"
        case .box: "x"
        case .image: "i"
        }
    }

    var icon: String {
        switch self {
        case .connector: "powerplug"
        case .splice: "arrow.triangle.merge"
        case .breakout: "arrow.triangle.branch"
        case .clip: "paperclip"
        case .matedPair: "link"
        case .wire: "cable.connector.horizontal"
        case .bundle: "line.diagonal"
        case .label: "tag"
        case .sticky: "note.text"
        case .frame: "rectangle.dashed"
        case .text: "textformat"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .image: "photo"
        }
    }
}

extension HarnessDocument {
    /// Where an insert lands when it has no click point: the pointer's last position on the drawing,
    /// else a spot near the top-left that moves along so repeated inserts don't stack.
    func insertionPoint() -> CGPoint {
        if let p = lastPointer { return p }
        fallbackInsertCount += 1
        let n = CGFloat(fallbackInsertCount % 8)
        return CGPoint(x: 160 + n * 60, y: 160 + n * 40)
    }

    /// Nearest bundle segment within `tolerance` points, with the position along it (0…1).
    func segment(near p: CGPoint, tolerance: Double = 10) -> (EntityID, Double)? {
        var best: (EntityID, Double, Double)?
        for seg in harness.segments {
            guard let a = harness.node(seg.nodeA)?.position, let b = harness.node(seg.nodeB)?.position else { continue }
            let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
            let d = hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
            if d < tolerance, d < (best?.2 ?? .infinity) { best = (seg.id, t, d) }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Connector or splice ids among the selected items, in designator order.
    var selectedEnds: [EntityID] {
        selectedNodeIDs.compactMap { n in
            harness.connectors.first { $0.nodeID == n }?.id ?? harness.splices.first { $0.nodeID == n }?.id
        }.sorted(by: naturalLess)
    }

    @MainActor
    func insert(_ kind: InsertKind, at point: CGPoint? = nil) {
        InsertTip().invalidate(reason: .actionPerformed)
        let p = snappedPoint(point ?? insertionPoint())
        switch kind {
        case .connector: requestPlacement(at: p)
        case .splice:
            // On a bundle, the splice is inserted into it.
            if let (sid, t) = segment(near: p) {
                perform("Insert Splice") { h in
                    guard let n = h.splitSegment(sid, at: t, kind: .splice) else { return }
                    let id = h.nextID(prefix: "SP")
                    h.splices.append(Splice(id: id, nodeID: n))
                    if let i = h.nodes.firstIndex(where: { $0.id == n }) { h.nodes[i].label = id }
                    selection = .splice(id)
                    multiSelection = [n]
                }
            } else {
                addNode(.splice, at: p)
            }
        case .breakout, .clip:
            let nodeKind: NodeKind = kind == .clip ? .clip : .breakout
            if let (sid, t) = segment(near: p) {
                perform("Insert \(nodeKind.rawValue.capitalized)") { h in
                    if let n = h.splitSegment(sid, at: t, kind: nodeKind) { selection = .node(n); multiSelection = [n] }
                }
            } else {
                addNode(nodeKind, at: p)
            }
        case .matedPair:
            guard let n = askNumber("In-line mated pair", "How many cavities in each half?", 4) else { return }
            perform("Add Mated Pair") { h in
                let (f, _) = h.addMatedPair(at: Point2D(p.x, p.y), cavities: n)
                selection = .connector(f)
            }
        case .sticky: addAnnotation(.sticky, at: p)
        case .frame: addAnnotation(.frame, at: p)
        case .wire:
            let ends = selectedEnds
            requestWire(from: ends.first, to: ends.dropFirst().first)
        case .bundle:
            let nodes = Array(selectedNodeIDs).sorted(by: naturalLess)
            guard nodes.count == 2 else {
                NSSound.beep()
                return
            }
            addSegment(nodes[0], nodes[1])
        case .label:
            guard let (sid, t) = segment(near: p, tolerance: 40), let s = harness.segment(sid) else {
                NSSound.beep()
                return
            }
            addLabel(on: sid, offsetMM: (t * s.lengthMM).rounded())
        case .text: addAnnotation(.text, at: p)
        case .arrow: addAnnotation(.arrow, at: p)
        case .box: addAnnotation(.rectangle, at: p)
        case .image:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
            panel.message = "Choose an image to place on the drawing."
            if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url),
               let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                addAnnotation(.image, at: p, image: png)
            }
        }
    }

    /// A small prompt for a count; nil when cancelled.
    func askNumber(_ title: String, _ question: String, _ initial: Int) -> Int? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = question
        let field = NSTextField(string: String(initial))
        field.frame = NSRect(x: 0, y: 0, width: 80, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let n = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), n > 0, n <= 300 else { return nil }
        return n
    }

    func snappedPoint(_ p: CGPoint) -> CGPoint {
        guard harness.settings.snapToGrid else { return p }
        let g = max(harness.settings.gridSize, 1)
        return CGPoint(x: (p.x / g).rounded() * g, y: (p.y / g).rounded() * g)
    }
}

/// The Insert menu in the menu bar.
struct InsertCommands: Commands {
    @FocusedObject var doc: HarnessDocument?

    var body: some Commands {
        CommandMenu("Insert") {
            Group {
                ForEach([InsertKind.connector, .matedPair, .splice, .breakout, .clip]) { k in
                    Button("\(k.title)  (\(String(k.key).uppercased()))") { doc?.insert(k) }
                }
                Divider()
                ForEach([InsertKind.wire, .bundle]) { k in
                    Button("\(k.title)  (\(String(k.key).uppercased()))") { doc?.insert(k) }
                }
                Divider()
                ForEach([InsertKind.label, .sticky, .frame, .text, .arrow, .box, .image]) { k in
                    Button("\(k.title)  (\(String(k.key).uppercased()))") { doc?.insert(k) }
                }
            }
            .disabled(doc == nil)
        }
    }
}
