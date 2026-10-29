import CoreGraphics
import CoreText
import CrimpCore
import Foundation
import ImageIO

/// Draws a harness into any CoreGraphics context with y pointing down (a SwiftUI Canvas, or a flipped PDF page).
/// The editor canvas and the PDF drawing use the same code, so the printout matches the screen.
public struct HarnessRenderer {
    public struct Options {
        public var highlightWireIDs: Set<EntityID> = []
        public var selectedIDs: Set<EntityID> = []
        public var showSegmentDimensions = true
        public var showNodes = true
        /// Points per mm of bundle diameter when `trueBundleWidth` (the 1:1 formboard); otherwise bundles are drawn as
        /// tubes whose width grows gently with the bundle so the drawing stays light and readable.
        public var bundleScale: CGFloat = 2.5
        public var trueBundleWidth = false
        public var ink: CGColor = CGColor(gray: 0.1, alpha: 1)
        public var secondaryInk: CGColor = CGColor(gray: 0.38, alpha: 1)
        public var accent: CGColor = CGColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1)
        /// Background colour used to fill label tags, tables and note flags.
        public var paper: CGColor = CGColor(gray: 1, alpha: 1)
        /// The bundle tube: its fill and outline.
        public var bundleFill: CGColor = CGColor(gray: 0.86, alpha: 1)
        public var bundleEdge: CGColor = CGColor(gray: 0.45, alpha: 1)
        /// Table header and grid colours.
        public var tableHeader: CGColor = CGColor(gray: 0.86, alpha: 1)
        public var tableGrid: CGColor = CGColor(gray: 0.62, alpha: 1)
        /// Selection rectangle being dragged, in canvas coordinates.
        public var marquee: CGRect?
        /// Supplies cached part photos; nil draws no photos.
        public var partImage: ((URL) -> CGImage?)? = { PartImageCache.shared.cached($0) }
        /// Which photo a part shows; the app and PDFs route this through the library so custom photos win.
        public var photoURL: (PartRef) -> URL? = { $0.imageURL }
        /// The editing canvas: outline unlocked connector tags and mark branch points so they can be grabbed.
        public var showUnlockedTags = false
        /// A connector's own picture (`Connector.imagePNG`), decoded once and cached.
        public var connectorImage: (Connector) -> CGImage? = { c in c.imagePNG.flatMap(ConnectorImageCache.image) }
        /// Draw connection tables and item numbers when the harness settings ask for them.
        public var honourSettings = true
        public init() {}
    }

    public let harness: Harness
    public let analysis: HarnessAnalysis
    public var options: Options

    /// Connection-table frames, placed once so tables avoid bundles and each other.
    private var placedTables: [EntityID: CGRect] = [:]
    /// Tables that had to go further away than beside their item; they get a leader line back to it.
    private var distantTables: Set<EntityID> = []
    /// BOM item numbers for each designator, every item it uses: C1 → [1, 7] (housing and contacts).
    private var itemLists: [EntityID: [Int]] = [:]

    public init(harness: Harness, analysis: HarnessAnalysis, options: Options = Options()) {
        self.harness = harness
        self.analysis = analysis
        self.options = options
        if showItems {
            var lists: [EntityID: [Int]] = [:]
            for line in analysis.bom {
                for ref in line.references {
                    let owner = String(ref.split(separator: ":").first.map(String.init) ?? ref).components(separatedBy: "/")[0]
                    if !(lists[owner]?.contains(line.item) ?? false) { lists[owner, default: []].append(line.item) }
                }
            }
            itemLists = lists.mapValues { $0.sorted() }
        }
        if showTables { (placedTables, distantTables) = placeTables() }
    }

    /// Bounding box of everything drawn, in canvas points.
    public var bounds: CGRect {
        var r = CGRect.null
        for n in harness.nodes { r = r.union(CGRect(x: n.position.x - 24, y: n.position.y - 24, width: 48, height: 48)) }
        for c in harness.connectors {
            if let f = connectorTag(c)?.frame { r = r.union(f.insetBy(dx: -8, dy: -8)) }
        }
        if showTables {
            for f in placedTables.values { r = r.union(f.insetBy(dx: -8, dy: -8)) }
        }
        for a in harness.annotations { r = r.union(CGRect(x: a.x, y: a.y, width: a.width, height: a.height).standardized.insetBy(dx: 0, dy: -12)) }
        return r.isNull ? CGRect(x: 0, y: 0, width: 400, height: 300) : r
    }

    var showTables: Bool { options.honourSettings && harness.settings.showConnectionTables == true }
    var showItems: Bool { options.honourSettings && harness.settings.showItemNumbers == true }

    /// "[1, 7]" for a designator when item numbers are shown, else "".
    func items(_ id: EntityID) -> String {
        guard showItems, let list = itemLists[id] ?? analysis.itemNumbers[id].map({ [$0] }), !list.isEmpty else { return "" }
        return "[" + list.map(String.init).joined(separator: ", ") + "]"
    }

    /// The picture drawn for a connector: its own image, else its part's photo.
    public func photo(for c: Connector) -> CGImage? {
        guard !c.kind.isLooseTerminal, harness.settings.showPartPhotos ?? true else { return nil }
        if let own = options.connectorImage(c) { return own }
        return c.part.flatMap(options.photoURL).flatMap { options.partImage?($0) }
    }

    public func draw(in cg: CGContext) {
        Signposts.interval("Draw harness") { drawContents(in: cg) }
    }

    // MARK: Bundle geometry

    /// Tube width for a segment.
    func bundleWidth(_ sid: EntityID) -> CGFloat {
        let d = CGFloat(analysis.bundleDiameterMM[sid] ?? 1)
        if options.trueBundleWidth { return max(1.5, d * options.bundleScale) }
        return min(11, max(4.5, 3.5 + d * 0.75))
    }

    /// Unit vector from a node along each bundle leaving it.
    func directions(from nodeID: EntityID) -> [CGVector] {
        guard let n = harness.node(nodeID) else { return [] }
        return harness.segments.compactMap { s -> CGVector? in
            guard s.nodeA == nodeID || s.nodeB == nodeID, let o = harness.node(s.nodeA == nodeID ? s.nodeB : s.nodeA) else { return nil }
            let dx = o.position.x - n.position.x, dy = o.position.y - n.position.y
            let len = max(hypot(dx, dy), 0.001)
            return CGVector(dx: dx / len, dy: dy / len)
        }
    }

    // MARK: Drawing

    private func drawContents(in cg: CGContext) {
        let h = harness
        for a in h.annotations.sorted(by: { $0.z < $1.z }) where a.z < 0 { drawAnnotation(a, cg) }

        // Bundles as tubes: every outline first, then every fill, so branches merge into one smooth shape.
        let covered = Dictionary(h.coverings.flatMap { c in c.segmentIDs.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
        cg.saveGState()
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        for seg in h.segments {
            guard let (p, q) = ends(seg.id) else { continue }
            let selected = options.selectedIDs.contains(seg.id)
            cg.setStrokeColor(selected ? options.accent : options.bundleEdge)
            cg.setLineWidth(bundleWidth(seg.id) + (selected ? 3 : 1.6))
            line(cg, p, q)
        }
        for seg in h.segments {
            guard let (p, q) = ends(seg.id) else { continue }
            cg.setStrokeColor(options.bundleFill)
            cg.setLineWidth(bundleWidth(seg.id))
            line(cg, p, q)
        }
        // Coverings shown on the tube: tape as fine wraps, sleeving and tube as a darker body with a dashed core.
        for seg in h.segments {
            guard let cov = covered[seg.id], let (p, q) = ends(seg.id) else { continue }
            drawCovering(cov, on: seg.id, from: p, to: q, cg)
        }
        cg.restoreGState()

        // Highlighted wires follow their route in their own colour.
        for wid in options.highlightWireIDs {
            guard let w = h.wire(wid), let route = analysis.routes[wid] else { continue }
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setStrokeColor(options.accent)
            cg.setLineWidth(6)
            for sid in route.segmentIDs { if let (p, q) = ends(sid) { line(cg, p, q) } }
            cg.setStrokeColor(color(WireTables.iecColors[w.color.base] ?? "#FF00FF"))
            cg.setLineWidth(2.5)
            for sid in route.segmentIDs { if let (p, q) = ends(sid) { line(cg, p, q) } }
        }

        if options.showSegmentDimensions {
            for seg in h.segments { drawDimension(seg, covering: covered[seg.id], cg) }
        }

        // In-line mated pairs: a mating mark between the two halves.
        for c in h.connectors {
            guard let m = c.mate, c.id < m, let a = c.nodeID.flatMap(h.node), let b = h.connector(m)?.nodeID.flatMap(h.node) else { continue }
            drawMate(CGPoint(x: a.position.x, y: a.position.y), CGPoint(x: b.position.x, y: b.position.y), cg)
        }

        // Bundle labels sit on the bundle, like a sleeve label.
        for l in h.labels {
            guard case let .segment(sid, off) = l.placement, let s = h.segment(sid), let (p, q) = ends(sid), s.lengthMM > 0 else { continue }
            let t = CGFloat(min(max(off / s.lengthMM, 0), 1))
            let at = CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
            labelBox(HarnessAnalysis.labelText(l, h), item: items(l.id), at: at, selected: options.selectedIDs.contains(l.id), cg)
        }

        if options.showNodes {
            for n in h.nodes { drawNode(n, cg) }
        }

        if showTables {
            for t in analysis.connectorTables { drawTable(t, cg) }
            for t in analysis.spliceTables { drawTable(t, cg) }
        }

        // Note flags
        for note in h.notes {
            for target in note.attachedTo {
                guard let at = anchor(of: target) else { continue }
                flag(note.id, at: CGPoint(x: at.x + 16, y: at.y - 26), cg)
            }
        }

        for a in h.annotations.sorted(by: { $0.z < $1.z }) where a.z >= 0 { drawAnnotation(a, cg) }

        if let m = options.marquee {
            cg.setFillColor(options.accent.copy(alpha: 0.12) ?? options.accent)
            cg.fill(m)
            cg.setStrokeColor(options.accent)
            cg.setLineWidth(1)
            cg.stroke(m)
        }
    }

    func drawCovering(_ cov: Covering, on sid: EntityID, from p: CGPoint, to q: CGPoint, _ cg: CGContext) {
        let w = bundleWidth(sid)
        let len = hypot(q.x - p.x, q.y - p.y)
        guard len > 1 else { return }
        let ux = (q.x - p.x) / len, uy = (q.y - p.y) / len
        let nx = -uy, ny = ux
        cg.saveGState()
        switch cov.kind {
        case .tape:
            // Short diagonal wraps along the tube.
            cg.setStrokeColor(options.bundleEdge.copy(alpha: 0.42) ?? options.bundleEdge)
            cg.setLineWidth(0.5)
            cg.setLineCap(.butt)
            var d: CGFloat = w / 2 + 2
            while d < len - w / 2 - 1 {
                let c = CGPoint(x: p.x + ux * d, y: p.y + uy * d)
                let half = w / 2 - 0.6
                cg.move(to: CGPoint(x: c.x + nx * half - ux * half * 0.6, y: c.y + ny * half - uy * half * 0.6))
                cg.addLine(to: CGPoint(x: c.x - nx * half + ux * half * 0.6, y: c.y - ny * half + uy * half * 0.6))
                d += 6
            }
            cg.strokePath()
        default:
            // Sleeving, tube and heat shrink: a darker body with a dashed centre line.
            cg.setStrokeColor(options.bundleEdge.copy(alpha: 0.35) ?? options.bundleEdge)
            cg.setLineWidth(max(1, w - 2))
            cg.setLineCap(.butt)
            line(cg, CGPoint(x: p.x + ux * w / 2, y: p.y + uy * w / 2), CGPoint(x: q.x - ux * w / 2, y: q.y - uy * w / 2))
            cg.setStrokeColor(options.bundleEdge)
            cg.setLineWidth(0.6)
            cg.setLineDash(phase: 0, lengths: [3, 2])
            line(cg, CGPoint(x: p.x + ux * w / 2, y: p.y + uy * w / 2), CGPoint(x: q.x - ux * w / 2, y: q.y - uy * w / 2))
        }
        cg.restoreGState()
    }

    struct Dimension {
        var origin: CGPoint
        var text: String
        var extra: String
        var textWidth: CGFloat
        var frame: CGRect
    }
    static let dimensionSize: CGFloat = 8.5

    /// Where a segment's length goes: beside the bundle at its middle (further along when a label sits there).
    func dimension(_ seg: Segment, covering: Covering?) -> Dimension? {
        guard let (p, q) = ends(seg.id) else { return nil }
        let labelled = harness.labels.contains { l in
            guard case let .segment(sid, off) = l.placement, sid == seg.id, seg.lengthMM > 0 else { return false }
            return abs(off / seg.lengthMM - 0.5) < 0.25
        }
        let t: CGFloat = labelled ? 0.8 : 0.5
        let mid = CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
        let len = max(hypot(q.x - p.x, q.y - p.y), 1)
        // Below a horizontal bundle, to the right of a vertical one, like a drawing dimension.
        var nx = -(q.y - p.y) / len, ny = (q.x - p.x) / len
        if ny < 0 || (abs(ny) < 0.2 && nx < 0) { nx = -nx; ny = -ny }
        let text = harness.settings.units.format(seg.lengthMM)
        let extra = covering.map { items($0.id) } ?? ""
        let size = Self.dimensionSize
        let w = TextDraw.width(text, size: size), we = extra.isEmpty ? 0 : TextDraw.width(" " + extra, size: size)
        let total = w + we
        let gap = bundleWidth(seg.id) / 2 + 5
        var origin = CGPoint(x: mid.x + nx * gap, y: mid.y + ny * gap)
        // Anchor the label's near edge to the bundle so slanted bundles don't run through the text.
        if abs(nx) > 0.5 {
            origin.x += nx > 0 ? 0 : -total
            origin.y -= size * 0.6
        } else {
            origin.x -= total / 2
            if ny < 0 { origin.y -= size + 2 }
        }
        return Dimension(origin: origin, text: text, extra: extra, textWidth: w,
                         frame: CGRect(x: origin.x, y: origin.y, width: total, height: size + 3))
    }

    /// "2 in [6]": the segment length, underlined, beside the bundle; covering item numbers in grey.
    func drawDimension(_ seg: Segment, covering: Covering?, _ cg: CGContext) {
        guard let d = dimension(seg, covering: covering) else { return }
        let size = Self.dimensionSize
        TextDraw.draw(d.text, in: cg, at: d.origin, size: size, color: options.ink)
        cg.setStrokeColor(options.ink)
        cg.setLineWidth(0.6)
        line(cg, CGPoint(x: d.origin.x, y: d.origin.y + size + 1.5), CGPoint(x: d.origin.x + d.textWidth, y: d.origin.y + size + 1.5))
        if !d.extra.isEmpty {
            TextDraw.draw(" " + d.extra, in: cg, at: CGPoint(x: d.origin.x + d.textWidth, y: d.origin.y), size: size, color: options.secondaryInk)
        }
    }

    func drawNode(_ n: TopologyNode, _ cg: CGContext) {
        let h = harness
        let p = CGPoint(x: n.position.x, y: n.position.y)
        let connector = h.connectors.first { $0.nodeID == n.id }
        let splices = h.splices.filter { $0.nodeID == n.id }
        let selected = options.selectedIDs.contains(n.id) || connector.map { options.selectedIDs.contains($0.id) } == true
            || splices.contains { options.selectedIDs.contains($0.id) }
        let ink = selected ? options.accent : options.ink
        switch n.kind {
        case .connector:
            guard let c = connector else {
                endRing(p, selected: selected, cg)
                return
            }
            let out = directions(from: n.id).first ?? CGVector(dx: 1, dy: 0)
            if c.kind.isLooseTerminal {
                drawLooseTerminal(c.kind, at: p, toward: out, selected: selected, cg)
            } else if c.kind == .loosePins {
                drawLooseTerminal(.quickConnect, at: p, toward: out, selected: selected, cg)
            } else if c.kind.isBox {
                let r = CGRect(x: p.x - 10, y: p.y - 8, width: 20, height: 16)
                cg.setFillColor(options.paper)
                cg.setStrokeColor(ink)
                cg.setLineWidth(selected ? 2 : 1.2)
                cg.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
                cg.drawPath(using: .fillStroke)
                TextDraw.draw(c.kind == .relay ? "K" : "F", in: cg, at: CGPoint(x: p.x, y: p.y - 5.5), size: 8.5, bold: true, color: ink, align: .center)
            } else {
                endRing(p, selected: selected, cg)
            }
            drawConnectorTag(c, at: p, selected: selected, cg)
        case .splice:
            // A green hexagon, like a splice symbol, with every splice at this junction named beside it.
            let r: CGFloat = 8
            let hex = CGMutablePath()
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3
                let pt = CGPoint(x: p.x + cos(a) * r * 1.25, y: p.y + sin(a) * r * 0.9)
                if i == 0 { hex.move(to: pt) } else { hex.addLine(to: pt) }
            }
            hex.closeSubpath()
            cg.setFillColor(CGColor(srgbRed: 0.55, green: 0.78, blue: 0.56, alpha: 1))
            cg.setStrokeColor(selected ? options.accent : CGColor(srgbRed: 0.18, green: 0.42, blue: 0.2, alpha: 1))
            cg.setLineWidth(selected ? 2 : 1)
            cg.addPath(hex)
            cg.drawPath(using: .fillStroke)
            let number = splices.first.map { $0.id.filter(\.isNumber) } ?? ""
            TextDraw.draw(splices.count > 1 ? "\(splices.count)" : number, in: cg, at: CGPoint(x: p.x, y: p.y - 4.5), size: 7.5, bold: true,
                          color: CGColor(gray: 0.05, alpha: 1), align: .center)
            let text = splices.isEmpty ? n.label : splices.map(\.id).joined(separator: " · ")
            let item = splices.map { items($0.id) }.first { !$0.isEmpty } ?? ""
            let side = labelSide(for: n.id)
            nameAndItems(text, item, near: p, side: side, offset: 13, size: 9, ink: ink, cg)
        case .breakout:
            // Branch points are just where the tube bends; on the canvas a small dot shows they can be grabbed.
            if options.showUnlockedTags || selected {
                cg.setFillColor(selected ? options.accent : options.bundleEdge)
                cg.fillEllipse(in: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5))
            }
        case .clip:
            let r = CGRect(x: p.x - 5, y: p.y - 7, width: 10, height: 14)
            cg.setFillColor(options.paper)
            cg.setStrokeColor(ink)
            cg.setLineWidth(1.2)
            cg.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil))
            cg.drawPath(using: .fillStroke)
            nameAndItems(n.label, items(n.id), near: p, side: labelSide(for: n.id), offset: 11, size: 8, ink: ink, cg)
        }
    }

    /// The small grey ring that marks where a connector sits on the bundle.
    func endRing(_ p: CGPoint, selected: Bool, _ cg: CGContext) {
        let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        cg.setFillColor(options.bundleFill)
        cg.setStrokeColor(selected ? options.accent : options.bundleEdge)
        cg.setLineWidth(selected ? 2.2 : 1.4)
        cg.fillEllipse(in: r)
        cg.strokeEllipse(in: r)
        cg.setFillColor(selected ? options.accent : options.bundleEdge)
        cg.fillEllipse(in: r.insetBy(dx: 2.8, dy: 2.8))
    }

    /// Ring, spade and quick-connect terminals: a crimp barrel on the bundle and the terminal's end beyond it.
    func drawLooseTerminal(_ kind: ConnectorKind, at p: CGPoint, toward out: CGVector, selected: Bool, _ cg: CGContext) {
        // The terminal points away from the bundle.
        let ux = -out.dx, uy = -out.dy
        let nx = -uy, ny = ux
        let ink = selected ? options.accent : options.ink
        cg.saveGState()
        // Barrel.
        let b0 = CGPoint(x: p.x - ux * 3, y: p.y - uy * 3), b1 = CGPoint(x: p.x + ux * 6, y: p.y + uy * 6)
        cg.setStrokeColor(ink)
        cg.setLineWidth(6)
        cg.setLineCap(.butt)
        line(cg, b0, b1)
        let c = CGPoint(x: p.x + ux * 13, y: p.y + uy * 13)
        cg.setLineWidth(selected ? 2.2 : 1.6)
        switch kind {
        case .ringTerminal:
            cg.setFillColor(options.bundleFill)
            let r = CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)
            cg.fillEllipse(in: r)
            cg.strokeEllipse(in: r)
            cg.setFillColor(options.paper)
            cg.fillEllipse(in: r.insetBy(dx: 3.5, dy: 3.5))
            cg.strokeEllipse(in: r.insetBy(dx: 3.5, dy: 3.5))
        case .spadeTerminal:
            for side in [-1.0, 1.0] {
                cg.move(to: CGPoint(x: b1.x + nx * 4 * side, y: b1.y + ny * 4 * side))
                cg.addLine(to: CGPoint(x: c.x + ux * 6 + nx * 4 * side, y: c.y + uy * 6 + ny * 4 * side))
            }
            cg.strokePath()
        default:
            // Pins, ferrules and quick-connects: a flat tab.
            cg.setFillColor(options.bundleFill)
            let tab = CGMutablePath()
            tab.move(to: CGPoint(x: b1.x + nx * 3, y: b1.y + ny * 3))
            tab.addLine(to: CGPoint(x: c.x + ux * 4 + nx * 3, y: c.y + uy * 4 + ny * 3))
            tab.addLine(to: CGPoint(x: c.x + ux * 4 - nx * 3, y: c.y + uy * 4 - ny * 3))
            tab.addLine(to: CGPoint(x: b1.x - nx * 3, y: b1.y - ny * 3))
            tab.closeSubpath()
            cg.addPath(tab)
            cg.drawPath(using: .fillStroke)
        }
        cg.restoreGState()
    }

    /// Where a node's name goes: on the side away from its bundles.
    enum Side { case left, right, above, below }

    func labelSide(for nodeID: EntityID) -> Side {
        let dirs = directions(from: nodeID)
        guard !dirs.isEmpty else { return .below }
        let sx = dirs.map(\.dx).reduce(0, +), sy = dirs.map(\.dy).reduce(0, +)
        if dirs.count > 1 && hypot(sx, sy) < 0.4 {
            // Bundles in several directions: the label goes in the largest gap; below is the usual choice.
            return dirs.contains { $0.dy > 0.7 } ? (dirs.contains { $0.dy < -0.7 } ? .right : .above) : .below
        }
        if abs(sx) >= abs(sy) { return sx > 0 ? .left : .right }
        return sy > 0 ? .above : .below
    }

    /// "S1 · S2 [15]" next to a point on the chosen side.
    func nameAndItems(_ name: String, _ item: String, near p: CGPoint, side: Side, offset: CGFloat, size: CGFloat, ink: CGColor, _ cg: CGContext) {
        guard !name.isEmpty else { return }
        let w = TextDraw.width(name, size: size, bold: true), wi = item.isEmpty ? 0 : TextDraw.width(" " + item, size: size)
        var o: CGPoint = switch side {
        case .left: CGPoint(x: p.x - offset - w - wi, y: p.y - size * 0.62)
        case .right: CGPoint(x: p.x + offset, y: p.y - size * 0.62)
        case .above: CGPoint(x: p.x - (w + wi) / 2, y: p.y - offset - size * 1.2)
        case .below: CGPoint(x: p.x - (w + wi) / 2, y: p.y + offset)
        }
        o.x = o.x.rounded()
        TextDraw.draw(name, in: cg, at: o, size: size, bold: true, color: ink)
        if !item.isEmpty { TextDraw.draw(" " + item, in: cg, at: CGPoint(x: o.x + w, y: o.y), size: size, color: options.secondaryInk) }
    }

    // MARK: Connector tags (photo + designator)

    /// A connector's photo and designator text, which move together ("tag").
    public struct ConnectorTag {
        /// Where the dot would be if the tag had not moved; photo and text are laid out around it.
        public var anchor: CGPoint
        public var photo: CGRect
        /// Top of the designator line.
        public var titleY: CGFloat
        /// Left edge of the designator line.
        public var titleX: CGFloat
        /// Photo plus text, for hit-testing and the leader line.
        public var frame: CGRect
        public var moved: Bool
        var side: Side = .below
    }

    static let titleSize: CGFloat = 10
    static let subtitleSize: CGFloat = 8

    /// The photo of a connector whose label is below its end: under the label, away from the bundle above.
    public static func photoBox(at p: CGPoint) -> CGRect {
        CGRect(x: p.x - 32, y: p.y + 40, width: 64, height: 50)
    }

    /// The tag laid out with its text below the dot and the photo above (a connector with no bundle direction).
    public static func tag(for c: Connector, at p: CGPoint, hasPhoto: Bool) -> ConnectorTag {
        layout(c, at: p, hasPhoto: hasPhoto, side: .below, title: c.id, item: "")
    }

    /// The tag as drawn: text on the side away from the bundle, photo beside the text.
    public func connectorTag(_ c: Connector) -> ConnectorTag? {
        guard let n = c.nodeID.flatMap(harness.node) else { return nil }
        let side = c.tagOffset == nil ? labelSide(for: n.id) : .below
        return Self.layout(c, at: CGPoint(x: n.position.x, y: n.position.y), hasPhoto: photo(for: c) != nil, side: side,
                           title: title(of: c), item: items(c.id))
    }

    func title(of c: Connector) -> String {
        // Mated halves show their gender, unless the designator already ends in F or M (C5F, C5M).
        let mark = c.gender == .female ? "F" : "M"
        return c.id + (c.mate != nil && !c.id.hasSuffix(mark) ? " (\(mark))" : "")
    }

    func subtitle(of c: Connector) -> String {
        var sub: [String] = [c.name]
        if c.name.isEmpty, let mpn = c.part?.mpn, !c.kind.isLooseTerminal, c.kind != .loosePins { sub = [mpn] }
        if c.kind.isBox, !c.boxItems.isEmpty {
            sub.append(c.boxItems.map { [$0.id, $0.rating].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: " · "))
        }
        return sub.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    static func layout(_ c: Connector, at p: CGPoint, hasPhoto: Bool, side: Side, title: String, item: String) -> ConnectorTag {
        let off = c.tagOffset.map { CGPoint(x: $0.x, y: $0.y) } ?? .zero
        let a = CGPoint(x: p.x + off.x, y: p.y + off.y)
        let gap: CGFloat = c.kind.isLooseTerminal || c.kind == .loosePins ? 24 : 12
        let textW = max(TextDraw.width(title, size: titleSize, bold: true) + (item.isEmpty ? 0 : TextDraw.width(" " + item, size: titleSize)),
                        min(200, TextDraw.width(c.name.isEmpty ? (c.part?.mpn ?? "") : c.name, size: subtitleSize)))
        let textH: CGFloat = 26
        var text: CGRect
        var photo: CGRect
        switch side {
        case .left:
            text = CGRect(x: a.x - gap - textW, y: a.y - titleSize * 0.65, width: textW, height: textH)
            photo = CGRect(x: text.maxX - 64, y: text.minY - 54, width: 64, height: 50)
        case .right:
            text = CGRect(x: a.x + gap, y: a.y - titleSize * 0.65, width: textW, height: textH)
            photo = CGRect(x: text.minX, y: text.minY - 54, width: 64, height: 50)
        case .above:
            text = CGRect(x: a.x - textW / 2, y: a.y - gap - textH, width: textW, height: textH)
            photo = CGRect(x: a.x - 32, y: text.minY - 54, width: 64, height: 50)
        case .below:
            text = CGRect(x: a.x - textW / 2, y: a.y + gap - 2, width: textW, height: textH)
            photo = photoBox(at: a)
        }
        var frame = text
        if hasPhoto { frame = frame.union(photo) }
        return ConnectorTag(anchor: a, photo: photo, titleY: text.minY, titleX: text.minX, frame: frame, moved: hypot(off.x, off.y) > 0.5, side: side)
    }

    func drawConnectorTag(_ c: Connector, at p: CGPoint, selected: Bool, _ cg: CGContext) {
        guard let tag = connectorTag(c) else { return }
        let ink = selected ? options.accent : options.ink
        if let img = photo(for: c) {
            let box = tag.photo
            let aspect = CGFloat(img.width) / CGFloat(max(img.height, 1))
            var fit = box
            if aspect > fit.width / fit.height {
                let hgt = fit.width / aspect
                fit.origin.y += fit.height - hgt
                fit.size.height = hgt
            } else {
                let wid = fit.height * aspect
                fit.origin.x += (fit.width - wid) / 2
                fit.size.width = wid
            }
            cg.saveGState()
            cg.translateBy(x: fit.minX, y: fit.maxY)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(img, in: CGRect(origin: .zero, size: fit.size))
            cg.restoreGState()
            if selected {
                cg.setStrokeColor(options.accent)
                cg.setLineWidth(1.5)
                cg.addPath(CGPath(roundedRect: fit.insetBy(dx: -3, dy: -3), cornerWidth: 4, cornerHeight: 4, transform: nil))
                cg.strokePath()
            }
        }
        if tag.moved {
            // Leader line from the dot to the nearest edge of the moved photo/text.
            let f = tag.frame
            let q = CGPoint(x: min(max(p.x, f.minX), f.maxX), y: min(max(p.y, f.minY), f.maxY))
            cg.saveGState()
            cg.setStrokeColor(options.secondaryInk)
            cg.setLineWidth(0.75)
            cg.setLineDash(phase: 0, lengths: [3, 2])
            line(cg, p, q)
            cg.restoreGState()
        }
        let title = title(of: c), item = items(c.id)
        let tw = TextDraw.width(title, size: Self.titleSize, bold: true) + (item.isEmpty ? 0 : TextDraw.width(" " + item, size: Self.titleSize))
        // Text hugs the dot on the left/right sides, and is centred above or below.
        let x: CGFloat = switch tag.side {
        case .left: tag.titleX + (tag.frame.width > 0 ? max(0, (connectorTextWidth(c, tag) - tw)) : 0)
        case .right: tag.titleX
        case .above, .below: tag.anchor.x - tw / 2
        }
        TextDraw.draw(title, in: cg, at: CGPoint(x: x, y: tag.titleY), size: Self.titleSize, bold: true, color: ink)
        if !item.isEmpty {
            TextDraw.draw(" " + item, in: cg, at: CGPoint(x: x + TextDraw.width(title, size: Self.titleSize, bold: true), y: tag.titleY),
                          size: Self.titleSize, color: options.secondaryInk)
        }
        let sub = subtitle(of: c)
        if !sub.isEmpty {
            let sw = min(200, TextDraw.width(sub, size: Self.subtitleSize))
            let sx: CGFloat = switch tag.side {
            case .left: x + tw - sw
            case .right: x
            case .above, .below: tag.anchor.x - sw / 2
            }
            TextDraw.draw(sub, in: cg, at: CGPoint(x: sx, y: tag.titleY + 13), size: Self.subtitleSize, color: options.secondaryInk, maxWidth: 200)
        }
        if options.showUnlockedTags, c.tagUnlocked == true {
            cg.saveGState()
            cg.setStrokeColor(options.accent)
            cg.setLineWidth(1)
            cg.setLineDash(phase: 0, lengths: [4, 3])
            cg.addPath(CGPath(roundedRect: tag.frame.insetBy(dx: -4, dy: -4), cornerWidth: 8, cornerHeight: 8, transform: nil))
            cg.strokePath()
            cg.restoreGState()
        }
    }

    private func connectorTextWidth(_ c: Connector, _ tag: ConnectorTag) -> CGFloat {
        let title = title(of: c), item = items(c.id)
        return max(TextDraw.width(title, size: Self.titleSize, bold: true) + (item.isEmpty ? 0 : TextDraw.width(" " + item, size: Self.titleSize)),
                   min(200, TextDraw.width(c.name.isEmpty ? (c.part?.mpn ?? "") : c.name, size: Self.subtitleSize)))
    }

    // MARK: Annotations

    func drawAnnotation(_ a: Annotation, _ cg: CGContext) {
        let r = CGRect(x: a.x, y: a.y, width: a.width, height: a.height)
        let ink = color(a.colorHex)
        let selected = options.selectedIDs.contains(a.id)
        cg.saveGState()
        cg.setStrokeColor(selected ? options.accent : ink)
        cg.setLineWidth(selected ? 2.5 : 1.5)
        switch a.kind {
        case .text:
            TextDraw.draw(a.text, in: cg, at: CGPoint(x: r.minX, y: r.minY), size: max(11, min(28, r.height * 0.45)), bold: r.height > 40,
                          color: ink, maxWidth: max(r.width, 40))
            if selected { cg.stroke(r.standardized) }
        case .rectangle:
            let box = r.standardized
            if a.text.isEmpty {
                cg.stroke(box)
            } else {
                // A titled box is a banner: grey panel with large bold text fitted to it.
                cg.setFillColor(CGColor(gray: 0.74, alpha: 1))
                cg.fill(box)
                cg.setLineWidth(selected ? 2.5 : 1.2)
                cg.stroke(box)
                var size = min(40, box.height * 0.38)
                var lines = wrappedLines(a.text, width: box.width - 16, size: size)
                while size > 9, CGFloat(lines.count) * size * 1.15 > box.height - 10 || lines.contains(where: { TextDraw.width($0, size: size, bold: true) > box.width - 16 }) {
                    size -= 1
                    lines = wrappedLines(a.text, width: box.width - 16, size: size)
                }
                var y = box.midY - CGFloat(lines.count) * size * 1.15 / 2
                for l in lines {
                    TextDraw.draw(l, in: cg, at: CGPoint(x: box.midX, y: y), size: size, bold: true, color: ink, align: .center)
                    y += size * 1.15
                }
            }
        case .ellipse:
            cg.strokeEllipse(in: r.standardized)
        case .arrow:
            let p = CGPoint(x: r.minX, y: r.minY), q = CGPoint(x: r.maxX, y: r.maxY)
            line(cg, p, q)
            let angle = atan2(q.y - p.y, q.x - p.x)
            cg.setFillColor(selected ? options.accent : ink)
            cg.move(to: q)
            cg.addLine(to: CGPoint(x: q.x - 10 * cos(angle - 0.4), y: q.y - 10 * sin(angle - 0.4)))
            cg.addLine(to: CGPoint(x: q.x - 10 * cos(angle + 0.4), y: q.y - 10 * sin(angle + 0.4)))
            cg.closePath(); cg.fillPath()
        case .frame:
            // A titled frame round a sub-harness or option: outline plus a title tab on the top edge.
            let box = r.standardized
            if a.dashed == true { cg.setLineDash(phase: 0, lengths: [8, 5]) }
            cg.setLineWidth(selected ? 2.5 : 1.25)
            cg.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil))
            cg.strokePath()
            cg.setLineDash(phase: 0, lengths: [])
            if !a.text.isEmpty {
                let w = min(TextDraw.width(a.text.uppercased(), size: 10, bold: true) + 20, box.width - 20)
                let tab = CGRect(x: box.minX + 14, y: box.minY - 9, width: w, height: 18)
                cg.setFillColor(selected ? options.accent : ink)
                cg.addPath(CGPath(roundedRect: tab, cornerWidth: 4, cornerHeight: 4, transform: nil))
                cg.fillPath()
                TextDraw.draw(a.text.uppercased(), in: cg, at: CGPoint(x: tab.minX + 10, y: tab.minY + 3.5), size: 10, bold: true,
                              color: options.paper, maxWidth: w - 20)
            }
        case .sticky:
            // A yellow callout card, like a drawing note.
            let box = r.standardized
            cg.setFillColor(CGColor(srgbRed: 1, green: 0.95, blue: 0.35, alpha: 1))
            cg.fill(box)
            cg.setStrokeColor(selected ? options.accent : CGColor(gray: 0.1, alpha: 1))
            cg.setLineWidth(selected ? 2 : 0.9)
            cg.stroke(box)
            let lines = wrappedLines(a.text, width: box.width - 12, size: 10)
            let total = CGFloat(lines.count) * 12.5
            var y = box.midY - total / 2
            for l in lines {
                TextDraw.draw(l, in: cg, at: CGPoint(x: box.midX, y: y), size: 10, bold: true, color: CGColor(gray: 0.05, alpha: 1), align: .center)
                y += 12.5
            }
        case .image:
            if let data = a.imagePNG, let img = Self.cgImage(data) {
                cg.saveGState()
                cg.translateBy(x: r.minX, y: r.maxY)
                cg.scaleBy(x: 1, y: -1)
                cg.draw(img, in: CGRect(origin: .zero, size: r.size))
                cg.restoreGState()
            } else {
                cg.stroke(r.standardized)
            }
            if selected { cg.stroke(r.standardized) }
        }
        cg.restoreGState()
    }

    func wrappedLines(_ s: String, width: CGFloat, size: CGFloat) -> [String] {
        var out: [String] = []
        for paragraph in s.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ") {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if TextDraw.width(candidate, size: size, bold: true) > width, !line.isEmpty {
                    out.append(line)
                    line = String(word)
                } else {
                    line = candidate
                }
            }
            out.append(line)
        }
        return out
    }

    /// The mating mark between the two halves of an in-line pair: facing brackets joined by a short line.
    func drawMate(_ a: CGPoint, _ b: CGPoint, _ cg: CGContext) {
        let len = max(hypot(b.x - a.x, b.y - a.y), 1)
        let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        cg.saveGState()
        cg.setStrokeColor(options.ink)
        cg.setLineWidth(1.5)
        cg.move(to: CGPoint(x: a.x + ux * 6, y: a.y + uy * 6))
        cg.addLine(to: CGPoint(x: b.x - ux * 6, y: b.y - uy * 6))
        cg.strokePath()
        for side in [-1.0, 1.0] {
            let c = CGPoint(x: mid.x + ux * 4 * side, y: mid.y + uy * 4 * side)
            cg.move(to: CGPoint(x: c.x - uy * 8, y: c.y + ux * 8))
            cg.addLine(to: CGPoint(x: c.x + uy * 8, y: c.y - ux * 8))
        }
        cg.strokePath()
        cg.restoreGState()
    }

    /// A bundle label: a white box sitting on the bundle, with its item number.
    func labelBox(_ text: String, item: String, at p: CGPoint, selected: Bool, _ cg: CGContext) {
        let size: CGFloat = 8.5
        let w = TextDraw.width(text, size: size) + 12
        let r = CGRect(x: p.x - w / 2, y: p.y - 7.5, width: w, height: 15)
        cg.setFillColor(options.paper)
        cg.fill(r)
        cg.setStrokeColor(selected ? options.accent : options.ink)
        cg.setLineWidth(selected ? 1.8 : 0.8)
        cg.stroke(r)
        TextDraw.draw(text, in: cg, at: CGPoint(x: p.x, y: r.minY + 3), size: size, color: options.ink, align: .center)
        if !item.isEmpty { TextDraw.draw(item, in: cg, at: CGPoint(x: r.midX, y: r.maxY + 2), size: 7.5, color: options.secondaryInk, align: .center) }
    }

    // MARK: Connection tables on the drawing

    /// Columns: pin (or wire, for splices), the other end, conductor name.colour, colour swatch, size, contact, twisted with.
    static let tableHeader = ["Pin", "To", "Conductor", "Color", "Size", "Contact", "Twisted"]
    static let tableRowHeight: CGFloat = 12.5
    static let tableFont: CGFloat = 8
    static let swatchColumn = 3

    struct TableRow {
        var cells: [String]
        var color: WireColor?
    }

    func tableRows(for id: EntityID) -> [TableRow]? {
        let wires = Dictionary(harness.wires.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let t = analysis.connectorTables.first(where: { $0.connectorID == id }) {
            let rows = t.rows.filter { !$0.wireID.isEmpty }.map { r in
                TableRow(cells: [r.cavity, r.destination.replacingOccurrences(of: ":", with: "."), r.conductor, "", r.size, r.terminal, r.twistedWith],
                         color: wires[r.wireID]?.color)
            }
            return rows.isEmpty ? nil : rows
        }
        if let t = analysis.spliceTables.first(where: { $0.connectorID == id }) {
            let rows = t.rows.map { r in
                TableRow(cells: [r.wireID, r.destination.replacingOccurrences(of: ":", with: "."), r.conductor, "", r.size, "", r.twistedWith],
                         color: wires[r.wireID]?.color)
            }
            return rows.isEmpty ? nil : rows
        }
        return nil
    }

    func tableColumnWidths(_ rows: [TableRow]) -> [CGFloat] {
        let header = Self.tableHeader
        return (0..<header.count).map { i -> CGFloat in
            if i == Self.swatchColumn { return 30 }
            // Optional columns collapse when nothing in them (contacts, twists).
            if i >= 5 && rows.allSatisfy({ $0.cells[i].isEmpty }) { return 0 }
            let texts = [header[i]] + rows.map { $0.cells[i] }
            return min(140, (texts.map { TextDraw.width($0, size: Self.tableFont, bold: false) }.max() ?? 0) + 10)
        }
    }

    /// Where a connector's or splice's connection table sits. Unmoved tables go to the first spot beside
    /// the item that no bundle or other table crosses; moved ones sit at `tableOffset` from their first spot.
    public func tableFrame(for id: EntityID) -> CGRect? { placedTables[id] }

    func placeTables() -> ([EntityID: CGRect], Set<EntityID>) {
        var placed: [EntityID: CGRect] = [:]
        var distant: Set<EntityID> = []
        let ids = harness.connectors.map(\.id) + harness.splices.map(\.id)
        // Moved tables first: they stay where they were put, and the others keep clear of them.
        for id in ids {
            guard let off = harness.connector(id)?.tableOffset ?? harness.splice(id)?.tableOffset,
                  let base = tableBase(for: id) else { continue }
            placed[id] = base.offsetBy(dx: off.x, dy: off.y)
        }
        let tags = harness.connectors.compactMap { connectorTag($0)?.frame }
        let labels: [CGRect] = harness.labels.compactMap { l in
            guard case let .segment(sid, off) = l.placement, let s = harness.segment(sid), let (p, q) = ends(sid), s.lengthMM > 0 else { return nil }
            let t = CGFloat(min(max(off / s.lengthMM, 0), 1))
            return CGRect(x: p.x + (q.x - p.x) * t - 40, y: p.y + (q.y - p.y) * t - 9, width: 80, height: 18)
        }
        // Notes, banners, text and pictures are obstacles; frames only surround things, so tables may sit inside them.
        let covered = Dictionary(harness.coverings.flatMap { c in c.segmentIDs.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
        let dims: [CGRect] = options.showSegmentDimensions ? harness.segments.compactMap { dimension($0, covering: covered[$0.id])?.frame } : []
        let notes = dims + harness.annotations.filter { [.sticky, .text, .rectangle, .image].contains($0.kind) }
            .map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).standardized }
        for id in ids where placed[id] == nil {
            guard let rows = tableRows(for: id), let spots = tableSpots(for: id, rows: rows) else { continue }
            let free = spots.first { r in
                let padded = r.insetBy(dx: -4, dy: -4)
                return !harness.segments.contains { seg in ends(seg.id).map { Self.crosses(padded, $0.0, $0.1) } ?? false }
                    && !placed.values.contains { $0.intersects(padded) }
                    && !tags.contains { $0.intersects(padded) }
                    && !labels.contains { $0.intersects(padded) }
                    && !notes.contains { $0.intersects(padded) }
            }
            if let free {
                placed[id] = free
                continue
            }
            // Nothing beside the item is free: search outward in rings for the nearest clear place.
            let r0 = spots[0]
            let centre = anchor(of: id) ?? CGPoint(x: r0.midX, y: r0.midY)
            var found: CGRect?
            search: for radius in stride(from: CGFloat(40), through: 900, by: 24) {
                for k in 0..<16 {
                    let a = CGFloat(k) * .pi / 8
                    let r = CGRect(x: centre.x + cos(a) * radius - r0.width / 2, y: centre.y + sin(a) * radius - r0.height / 2,
                                   width: r0.width, height: r0.height)
                    let padded = r.insetBy(dx: -4, dy: -4)
                    if !harness.segments.contains(where: { seg in ends(seg.id).map { Self.crosses(padded, $0.0, $0.1) } ?? false })
                        && !placed.values.contains(where: { $0.intersects(padded) })
                        && !tags.contains(where: { $0.intersects(padded) })
                        && !labels.contains(where: { $0.intersects(padded) })
                        && !notes.contains(where: { $0.intersects(padded) }) {
                        found = r
                        break search
                    }
                }
            }
            placed[id] = found ?? r0
            distant.insert(id)
        }
        return (placed, distant)
    }

    /// The spot under an item that `tableOffset` is measured from.
    public func tableBase(for id: EntityID) -> CGRect? {
        guard let rows = tableRows(for: id) else { return nil }
        return tableSpots(for: id, rows: rows)?.first
    }

    /// Candidate places for a table, best first: beside the connector's text, away from the bundle.
    func tableSpots(for id: EntityID, rows: [TableRow]) -> [CGRect]? {
        let w = tableColumnWidths(rows).reduce(0, +)
        let h = CGFloat(rows.count + 1) * Self.tableRowHeight
        if let c = harness.connector(id), let tag = connectorTag(c) {
            let t = tag.frame
            let a = tag.anchor
            let left = CGRect(x: t.minX - 12 - w, y: t.minY, width: w, height: h)
            let right = CGRect(x: t.maxX + 12, y: t.minY, width: w, height: h)
            let below = CGRect(x: a.x - w / 2, y: t.maxY + 8, width: w, height: h)
            let above = CGRect(x: a.x - w / 2, y: t.minY - 8 - h, width: w, height: h)
            let order: [CGRect] = switch tag.side {
            case .left: [left, below, above, right]
            case .right: [right, below, above, left]
            case .above: [above, left, right, below]
            case .below: [below, right, left, above]
            }
            // Also try sliding along the preferred side.
            return order + [left.offsetBy(dx: 0, dy: -h / 2), right.offsetBy(dx: 0, dy: -h / 2),
                            below.offsetBy(dx: w / 2 + 20, dy: 0), below.offsetBy(dx: -w / 2 - 20, dy: 0)]
        }
        if let s = harness.splice(id), let n = s.nodeID.flatMap(harness.node) {
            let p = CGPoint(x: n.position.x, y: n.position.y)
            return [CGRect(x: p.x + 18, y: p.y + 18, width: w, height: h),
                    CGRect(x: p.x - 18 - w, y: p.y + 18, width: w, height: h),
                    CGRect(x: p.x + 18, y: p.y - 18 - h, width: w, height: h),
                    CGRect(x: p.x - 18 - w, y: p.y - 18 - h, width: w, height: h),
                    CGRect(x: p.x - w / 2, y: p.y + 30, width: w, height: h),
                    CGRect(x: p.x - w / 2, y: p.y - 30 - h, width: w, height: h)]
        }
        return nil
    }

    /// Whether the line from `p` to `q` passes through `r`.
    static func crosses(_ r: CGRect, _ p: CGPoint, _ q: CGPoint) -> Bool {
        if r.contains(p) || r.contains(q) { return true }
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let d1 = cross(p, q, a), d2 = cross(p, q, b), d3 = cross(a, b, p), d4 = cross(a, b, q)
            if (d1 > 0) != (d2 > 0), (d3 > 0) != (d4 > 0) { return true }
        }
        return false
    }

    func drawTable(_ t: ConnectorTable, _ cg: CGContext) {
        guard let rows = tableRows(for: t.connectorID), let f = tableFrame(for: t.connectorID) else { return }
        let widths = tableColumnWidths(rows)
        let rh = Self.tableRowHeight, size = Self.tableFont
        let selected = options.selectedIDs.contains(t.connectorID)
        let isSplice = harness.splice(t.connectorID) != nil
        cg.saveGState()
        cg.setFillColor(options.paper)
        cg.fill(f)
        cg.setFillColor(options.tableHeader)
        cg.fill(CGRect(x: f.minX, y: f.minY, width: f.width, height: rh))
        var x = f.minX
        for (i, head) in Self.tableHeader.enumerated() where widths[i] > 0 {
            let text = i == 0 && isSplice ? "Wire" : head
            TextDraw.draw(text, in: cg, at: CGPoint(x: x + 4, y: f.minY + 2.2), size: size, color: options.ink, maxWidth: widths[i] - 6)
            x += widths[i]
        }
        for (r, row) in rows.enumerated() {
            let y = f.minY + CGFloat(r + 1) * rh
            x = f.minX
            for (i, text) in row.cells.enumerated() where widths[i] > 0 {
                if i == Self.swatchColumn, let wc = row.color {
                    swatch(wc, in: CGRect(x: x + 4, y: y + 3, width: widths[i] - 8, height: rh - 6), cg)
                } else {
                    TextDraw.draw(text, in: cg, at: CGPoint(x: x + 4, y: y + 2.2), size: size, color: options.ink, maxWidth: widths[i] - 6)
                }
                x += widths[i]
            }
        }
        // Grid.
        cg.setStrokeColor(options.tableGrid)
        cg.setLineWidth(0.4)
        for r in 1...rows.count {
            let y = f.minY + CGFloat(r) * rh
            line(cg, CGPoint(x: f.minX, y: y), CGPoint(x: f.maxX, y: y))
        }
        x = f.minX
        for w in widths.dropLast() where w > 0 {
            x += w
            line(cg, CGPoint(x: x, y: f.minY), CGPoint(x: x, y: f.maxY))
        }
        cg.setStrokeColor(selected ? options.accent : options.ink)
        cg.setLineWidth(selected ? 1.6 : 0.8)
        cg.stroke(f)
        cg.restoreGState()
        // A leader back to the item when the table has been moved away from it.
        let moved = distantTables.contains(t.connectorID)
            || (harness.connector(t.connectorID)?.tableOffset ?? harness.splice(t.connectorID)?.tableOffset).map { hypot($0.x, $0.y) > 0.5 } ?? false
        if moved, let at = anchor(of: t.connectorID) {
            let q = CGPoint(x: min(max(at.x, f.minX), f.maxX), y: min(max(at.y, f.minY), f.maxY))
            cg.saveGState()
            cg.setStrokeColor(options.secondaryInk)
            cg.setLineWidth(0.6)
            cg.setLineDash(phase: 0, lengths: [2, 2])
            line(cg, at, q)
            cg.restoreGState()
        }
    }

    /// A wire colour swatch: the base colour with its stripe as a diagonal band.
    func swatch(_ c: WireColor, in r: CGRect, _ cg: CGContext) {
        cg.saveGState()
        cg.setFillColor(color(WireTables.iecColors[c.base] ?? "#999999"))
        cg.fill(r)
        if let s = c.stripe {
            cg.clip(to: r)
            cg.setStrokeColor(color(WireTables.iecColors[s] ?? "#999999"))
            cg.setLineWidth(r.height * 0.45)
            line(cg, CGPoint(x: r.maxX - r.height * 1.2, y: r.maxY + 1), CGPoint(x: r.maxX - r.height * 0.1, y: r.minY - 1))
        }
        cg.restoreGState()
        cg.setStrokeColor(CGColor(gray: 0.25, alpha: 1))
        cg.setLineWidth(0.5)
        cg.stroke(r)
    }

    func flag(_ n: Int, at p: CGPoint, _ cg: CGContext) {
        cg.setStrokeColor(options.ink)
        cg.setFillColor(options.paper)
        cg.setLineWidth(1)
        cg.move(to: CGPoint(x: p.x, y: p.y - 9))
        cg.addLine(to: CGPoint(x: p.x + 10, y: p.y + 7))
        cg.addLine(to: CGPoint(x: p.x - 10, y: p.y + 7))
        cg.closePath()
        cg.drawPath(using: .fillStroke)
        TextDraw.draw("\(n)", in: cg, at: CGPoint(x: p.x, y: p.y - 3), size: 8, bold: true, color: options.ink, align: .center)
    }

    /// Where an item sits on the drawing, for flags and "locate" in the app.
    public func anchor(of id: EntityID) -> CGPoint? {
        let h = harness
        let nodeID = h.connector(id)?.nodeID ?? h.splice(id)?.nodeID ?? h.node(id)?.id
        if let nodeID, let n = h.node(nodeID) { return CGPoint(x: n.position.x, y: n.position.y) }
        if let (p, q) = ends(id) { return CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2) }
        if let c = h.coverings.first(where: { $0.id == id }), let s = c.segmentIDs.first { return anchor(of: s) }
        if let w = h.wire(id), let s = analysis.routes[w.id]?.segmentIDs.first { return anchor(of: s) }
        return nil
    }

    func ends(_ sid: EntityID) -> (CGPoint, CGPoint)? {
        guard let s = harness.segment(sid), let a = harness.node(s.nodeA), let b = harness.node(s.nodeB) else { return nil }
        return (CGPoint(x: a.position.x, y: a.position.y), CGPoint(x: b.position.x, y: b.position.y))
    }

    func line(_ cg: CGContext, _ p: CGPoint, _ q: CGPoint) {
        cg.move(to: p)
        cg.addLine(to: q)
        cg.strokePath()
    }

    public static func cgImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

public func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    let v = UInt32(s, radix: 16) ?? 0x333333
    return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
}

/// Decoded `Connector.imagePNG` pictures, keyed by the bytes, so redraws don't decode them again.
public enum ConnectorImageCache {
    nonisolated(unsafe) private static var cache: [Data: CGImage] = [:]
    private static let lock = NSLock()

    public static func image(_ data: Data) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let img = cache[data] { return img }
        guard let img = HarnessRenderer.cgImage(data) else { return nil }
        if cache.count > 64 { cache.removeAll() }
        cache[data] = img
        return img
    }
}

/// CoreText drawing for y-down contexts.
public enum TextDraw {
    public enum Align { case left, center, right }

    static func line(_ s: String, size: CGFloat, bold: Bool, color: CGColor) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }

    public static func width(_ s: String, size: CGFloat, bold: Bool = false) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(s, size: size, bold: bold, color: CGColor(gray: 0, alpha: 1)), nil, nil, nil))
    }

    /// Wraps text into a rectangle (top-aligned); lines that don't fit are dropped.
    public static func drawWrapped(_ s: String, in cg: CGContext, rect: CGRect, size: CGFloat, bold: Bool = false, color: CGColor) {
        guard !s.isEmpty, rect.width > 4 else { return }
        var y = rect.minY
        let lineHeight = size * 1.25
        for paragraph in s.components(separatedBy: "\n") {
            var line = ""
            func flush() {
                if y + lineHeight <= rect.maxY + 1 { draw(line, in: cg, at: CGPoint(x: rect.minX, y: y), size: size, bold: bold, color: color, maxWidth: rect.width) }
                y += lineHeight
                line = ""
            }
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if width(candidate, size: size, bold: bold) > rect.width, !line.isEmpty {
                    flush()
                    line = String(word)
                } else {
                    line = candidate
                }
            }
            flush()
        }
    }

    /// `at` is the top of the text box. Text longer than `maxWidth` is truncated with an ellipsis.
    public static func draw(_ s: String, in cg: CGContext, at p: CGPoint, size: CGFloat, bold: Bool = false,
                            color: CGColor, align: Align = .left, maxWidth: CGFloat? = nil) {
        guard !s.isEmpty else { return }
        var l = line(s, size: size, bold: bold, color: color)
        if let maxWidth, CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) > maxWidth {
            let token = line("…", size: size, bold: bold, color: color)
            l = CTLineCreateTruncatedLine(l, Double(maxWidth), .end, token) ?? l
        }
        var ascent: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(l, &ascent, nil, nil))
        let x: CGFloat = switch align {
        case .left: p.x
        case .center: p.x - w / 2
        case .right: p.x - w
        }
        cg.saveGState()
        cg.translateBy(x: x, y: p.y + ascent)
        cg.scaleBy(x: 1, y: -1)
        cg.textPosition = .zero
        CTLineDraw(l, cg)
        cg.restoreGState()
    }
}
