import CoreGraphics
import CrimpCore
import Foundation

/// Draws the system diagram (devices, harnesses, connectors and mates) into a y-down context.
public struct SystemRenderer {
    public struct Options {
        public var selectedBlock: SystemBlockID?
        public var selectedMate: EntityID?
        public var pendingPort: ConnectorRef?
        /// Connectors and mates on a traced net are highlighted.
        public var highlightConnectors: Set<ConnectorRef> = []
        public var highlightMates: Set<EntityID> = []
        public var ink = CGColor(gray: 0.1, alpha: 1)
        public var secondaryInk = CGColor(gray: 0.45, alpha: 1)
        public var paper = CGColor(gray: 1, alpha: 1)
        public var accent = CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
        public var highlight = CGColor(srgbRed: 1, green: 0.55, blue: 0, alpha: 1)
        public init() {}
    }

    public let project: SystemProject
    public let layout: SystemLayout
    public var options: Options

    public init(project: SystemProject, layout: SystemLayout? = nil, options: Options = Options()) {
        self.project = project
        self.layout = layout ?? SystemLayout(project)
        self.options = options
    }

    public func draw(in cg: CGContext) {
        // Mates under the blocks, as gentle curves.
        for m in project.mates {
            guard let (a, b) = layout.line(m) else { continue }
            let hot = options.highlightMates.contains(m.id)
            let selected = options.selectedMate == m.id
            cg.setStrokeColor(selected ? options.accent : hot ? options.highlight : options.ink)
            cg.setLineWidth(selected || hot ? 3 : 1.5)
            let dx = max(abs(b.x - a.x) * 0.4, 30)
            let outA: CGFloat = a.x <= (layout.blocks.first { $0.rows.contains { $0.ref == m.a } }?.frame.midX ?? a.x) ? -1 : 1
            let outB: CGFloat = b.x <= (layout.blocks.first { $0.rows.contains { $0.ref == m.b } }?.frame.midX ?? b.x) ? -1 : 1
            cg.move(to: a)
            cg.addCurve(to: b, control1: CGPoint(x: a.x + outA * dx, y: a.y), control2: CGPoint(x: b.x + outB * dx, y: b.y))
            cg.strokePath()
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let w = TextDraw.width(m.id, size: 8, bold: true) + 8
            cg.setFillColor(options.paper)
            cg.fill(CGRect(x: mid.x - w / 2, y: mid.y - 7, width: w, height: 13))
            TextDraw.draw(m.id, in: cg, at: CGPoint(x: mid.x, y: mid.y - 5.5), size: 8, bold: true,
                          color: selected ? options.accent : options.ink, align: .center)
        }

        for block in layout.blocks {
            let isDevice: Bool = if case .device = block.id { true } else { false }
            let selected = options.selectedBlock == block.id
            let path = CGPath(roundedRect: block.frame, cornerWidth: 8, cornerHeight: 8, transform: nil)
            cg.setFillColor(options.paper)
            cg.addPath(path); cg.fillPath()
            // Header band
            cg.saveGState()
            cg.addPath(path); cg.clip()
            cg.setFillColor(isDevice ? CGColor(srgbRed: 0.33, green: 0.36, blue: 0.42, alpha: 1) : CGColor(srgbRed: 0.12, green: 0.42, blue: 0.75, alpha: 1))
            cg.fill(CGRect(x: block.frame.minX, y: block.frame.minY, width: block.frame.width, height: SystemLayout.headerHeight))
            cg.restoreGState()
            cg.setStrokeColor(selected ? options.accent : options.ink)
            cg.setLineWidth(selected ? 3 : 1)
            cg.addPath(path); cg.strokePath()
            let white = CGColor(gray: 1, alpha: 1)
            TextDraw.draw((isDevice ? "DEVICE  " : "HARNESS  ") + block.title, in: cg,
                          at: CGPoint(x: block.frame.minX + 10, y: block.frame.minY + 6), size: 10, bold: true, color: white,
                          maxWidth: block.frame.width - 20)
            TextDraw.draw(block.subtitle, in: cg, at: CGPoint(x: block.frame.minX + 10, y: block.frame.minY + 22), size: 8.5,
                          color: CGColor(gray: 1, alpha: 0.85), maxWidth: block.frame.width - 20)

            for (i, row) in block.rows.enumerated() {
                let r = block.rowRect(i)
                let hot = options.highlightConnectors.contains(row.ref)
                let pending = options.pendingPort == row.ref
                if hot || pending {
                    cg.setFillColor((pending ? options.accent : options.highlight).copy(alpha: 0.2) ?? options.highlight)
                    cg.fill(r.insetBy(dx: 2, dy: 1))
                }
                TextDraw.draw(row.title, in: cg, at: CGPoint(x: r.minX + 12, y: r.minY + 5), size: 9, color: options.ink, maxWidth: r.width - 70)
                TextDraw.draw(row.detail, in: cg, at: CGPoint(x: r.maxX - 12, y: r.minY + 5), size: 8, color: options.secondaryInk, align: .right)
                let mated = project.mate(for: row.ref) != nil
                for x in [r.minX, r.maxX] {
                    let dot = CGRect(x: x - 4, y: r.midY - 4, width: 8, height: 8)
                    cg.setFillColor(mated ? (hot ? options.highlight : options.ink) : options.paper)
                    cg.fillEllipse(in: dot)
                    cg.setStrokeColor(hot ? options.highlight : options.ink)
                    cg.setLineWidth(1)
                    cg.strokeEllipse(in: dot)
                }
            }
            if block.rows.isEmpty {
                TextDraw.draw("No connectors", in: cg, at: CGPoint(x: block.frame.minX + 12, y: block.frame.minY + SystemLayout.headerHeight + 5),
                              size: 9, color: options.secondaryInk)
            }
        }
    }
}

public enum SystemPDF {
    /// System drawing set: diagram, netlist, BOM, mates and rule check, then each harness's own drawing set.
    public static func make(_ p: SystemProject, analysis: SystemAnalysis? = nil, includeHarnessDrawings: Bool = true) -> Data {
        let a = analysis ?? SystemAnalysis(p)
        var meta = Harness(name: p.name, revision: p.revision)
        meta.titleBlock = p.titleBlock
        meta.revisions = p.revisions
        let set = PDFDrawingSet(harness: meta, analysis: HarnessAnalysis(meta))
        let renderer = SystemRenderer(project: p)

        set.pages.append(PDFDrawingSet.Page(frame: set.frame, title: "System diagram", draw: { cg, rect in
            let b = renderer.layout.bounds
            guard !b.isNull, b.width > 0 else { return }
            let scale = min(rect.width / b.width, rect.height / b.height, 1.6)
            cg.saveGState()
            cg.translateBy(x: rect.midX - b.midX * scale, y: rect.midY - b.midY * scale)
            cg.scaleBy(x: scale, y: scale)
            renderer.draw(in: cg)
            cg.restoreGState()
        }))
        set.table("System netlist", groups: [(nil, ["Net", "Device pins", "Harness pins", "Wires"], [0.14, 0.24, 0.36, 0.26],
                                              a.nets.map { n in [n.name, n.devicePins.joined(separator: ", "),
                                                                  n.pins.filter { !n.devicePins.contains($0) }.joined(separator: ", "),
                                                                  n.wires.joined(separator: ", ")] })])
        let ids = p.harnesses.map(\.id)
        let qtyWidth = min(0.07, 0.3 / CGFloat(max(ids.count, 1)))
        let fixed: [CGFloat] = [0.09, 0.15, 0.13, 0.25, 0.08]
        let rest = max(0.05, 1 - fixed.reduce(0, +) - qtyWidth * CGFloat(ids.count))
        set.table("System bill of materials", groups: [(nil, ["Category", "MPN", "Manufacturer", "Description", "Total"] + ids + ["References"],
                                                        fixed + Array(repeating: qtyWidth, count: ids.count) + [rest],
                                                        a.bom.map { b in
                                                            let l = b.line
                                                            func q(_ v: Double?) -> String {
                                                                guard let v else { return "" }
                                                                return l.unit == .mm ? String(format: "%.0f mm", v) : String(format: "%g", v)
                                                            }
                                                            return [l.category, l.mpn, l.manufacturer, l.description, q(l.quantity)]
                                                                + ids.map { q(b.breakdown[$0]) } + [l.references.joined(separator: " ")]
                                                        })])
        set.table("Mates", groups: [(nil, ["Mate", "Side A", "Side B", "Pin map"], [0.08, 0.32, 0.32, 0.28],
                                     p.mates.map { m in [m.id, p.displayName(of: m.a), p.displayName(of: m.b),
                                                         m.pinMap.isEmpty ? "1:1 by label" : m.pinMap.sorted { naturalLess($0.key, $1.key) }.map { "\($0.key)→\($0.value)" }.joined(separator: ", ")] })])
        set.table("System rule check", groups: [(nil, ["Severity", "Item", "Message"], [0.1, 0.18, 0.72],
                                                 a.issues.map { [$0.severity.rawValue, $0.subject, $0.message] })])
        if includeHarnessDrawings {
            for inst in p.harnesses {
                let sub = PDFDrawingSet(harness: inst.harness, analysis: a.harnessAnalyses[inst.id] ?? HarnessAnalysis(inst.harness))
                for page in DrawingPage.allCases { sub.add(page) }
                set.pages += sub.pages.map { var pg = $0; pg.title = "\(inst.id) — \(pg.title)"; return pg }
            }
        }
        return set.render()
    }
}
