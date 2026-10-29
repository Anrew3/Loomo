import CoreGraphics
import Foundation

public enum SystemBlockID: Hashable, Sendable {
    case device(EntityID), harness(EntityID)

    public var id: EntityID {
        switch self { case let .device(i), let .harness(i): i }
    }
}

/// Geometry of the system diagram: one block per device and harness, one row (with ports on both sides) per connector.
/// Shared by the editor canvas and the PDF so hit-testing and printing agree.
public struct SystemLayout: Sendable {
    public static let blockWidth: CGFloat = 240
    public static let headerHeight: CGFloat = 40
    public static let rowHeight: CGFloat = 22

    public struct Row: Sendable {
        public var ref: ConnectorRef
        public var title: String
        public var detail: String
    }

    public struct Block: Sendable {
        public var id: SystemBlockID
        public var title: String
        public var subtitle: String
        public var frame: CGRect
        public var rows: [Row]

        public func rowRect(_ i: Int) -> CGRect {
            CGRect(x: frame.minX, y: frame.minY + SystemLayout.headerHeight + CGFloat(i) * SystemLayout.rowHeight,
                   width: frame.width, height: SystemLayout.rowHeight)
        }
    }

    public let blocks: [Block]

    public init(_ p: SystemProject) {
        var blocks: [Block] = []
        for d in p.devices {
            let rows = d.connectors.map { c in
                Row(ref: .device(d.id, connector: c.id), title: [c.id, c.name].filter { !$0.isEmpty }.joined(separator: " "),
                    detail: "\(c.pins.count)p \(c.gender == .male ? "♂" : "♀")")
            }
            blocks.append(Block(id: .device(d.id), title: d.id, subtitle: d.name.isEmpty ? "Device" : d.name,
                                frame: Self.frame(d.position, rows.count), rows: rows))
        }
        for i in p.harnesses {
            let rows = i.harness.connectors.filter { !$0.kind.isLooseTerminal }.map { c in
                Row(ref: .harness(i.id, connector: c.id), title: [c.id, c.name].filter { !$0.isEmpty }.joined(separator: " "),
                    detail: "\(c.cavities.count)p \(c.gender == .male ? "♂" : "♀")")
            }
            blocks.append(Block(id: .harness(i.id), title: "\(i.id)" + (i.quantity > 1 ? " ×\(i.quantity)" : ""),
                                subtitle: i.harness.name, frame: Self.frame(i.position, rows.count), rows: rows))
        }
        self.blocks = blocks
    }

    static func frame(_ origin: Point2D, _ rows: Int) -> CGRect {
        CGRect(x: origin.x, y: origin.y, width: blockWidth, height: headerHeight + CGFloat(max(rows, 1)) * rowHeight + 6)
    }

    public var bounds: CGRect {
        blocks.reduce(CGRect.null) { $0.union($1.frame) }.insetBy(dx: -30, dy: -30)
    }

    /// Port positions on the left and right edge of a connector's row.
    public func ports(_ ref: ConnectorRef) -> (left: CGPoint, right: CGPoint)? {
        for b in blocks {
            if let i = b.rows.firstIndex(where: { $0.ref == ref }) {
                let r = b.rowRect(i)
                return (CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY))
            }
        }
        return nil
    }

    /// The pair of ports (one per side) that gives the shortest line.
    public func line(_ m: Mate) -> (CGPoint, CGPoint)? {
        guard let a = ports(m.a), let b = ports(m.b) else { return nil }
        let pairs = [(a.left, b.left), (a.left, b.right), (a.right, b.left), (a.right, b.right)]
        return pairs.min { hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) < hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) }
    }

    public func hitBlock(_ p: CGPoint) -> Block? {
        blocks.last { $0.frame.contains(p) }
    }

    /// The connector row under a point, if any.
    public func hitRow(_ p: CGPoint) -> ConnectorRef? {
        for b in blocks.reversed() where b.frame.insetBy(dx: -8, dy: 0).contains(p) {
            for (i, row) in b.rows.enumerated() where b.rowRect(i).insetBy(dx: -8, dy: 0).contains(p) { return row.ref }
        }
        return nil
    }

    public func hitMate(_ p: CGPoint, mates: [Mate]) -> EntityID? {
        var best: (EntityID, CGFloat)?
        for m in mates {
            guard let (a, b) = line(m) else { continue }
            let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
            let d = hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
            if d < 8, d < (best?.1 ?? .infinity) { best = (m.id, d) }
        }
        return best?.0
    }
}

public extension SystemAnalysis {
    func workbook(for p: SystemProject) -> XLSXWriter {
        func t(_ s: String) -> XLSXWriter.Cell { .text(s) }
        let instanceIDs = p.harnesses.map(\.id) + (p.devices.contains { $0.part != nil || $0.connectors.contains { $0.part != nil } } ? ["Devices"] : [])
        var sheets: [XLSXWriter.Sheet] = []
        sheets.append(.init(name: "System BOM",
                            header: ["Category", "Internal PN", "MPN", "Manufacturer", "Description", "Total", "Unit"] + instanceIDs + ["References"],
                            rows: bom.map { b in
                                let l = b.line
                                return [t(l.category), t(l.internalPN), t(l.mpn), t(l.manufacturer), t(l.description),
                                        .number((l.quantity * 100).rounded() / 100), t(l.unit.rawValue)]
                                    + instanceIDs.map { b.breakdown[$0].map { .number(($0 * 100).rounded() / 100) } ?? t("") }
                                    + [t(l.references.joined(separator: " "))]
                            }))
        sheets.append(.init(name: "System netlist", header: ["Net", "Device pins", "All pins", "Wires", "Harnesses"],
                            rows: nets.map { [t($0.name), t($0.devicePins.joined(separator: ", ")), t($0.pins.joined(separator: ", ")),
                                              t($0.wires.joined(separator: ", ")), t($0.harnesses.joined(separator: ", "))] }))
        sheets.append(.init(name: "Mates", header: ["Mate", "A", "B", "Pin map"],
                            rows: p.mates.map { m in [t(m.id), t(p.displayName(of: m.a)), t(p.displayName(of: m.b)),
                                                      t(m.pinMap.sorted { naturalLess($0.key, $1.key) }.map { "\($0.key)→\($0.value)" }.joined(separator: ", "))] }))
        sheets.append(.init(name: "Device pins", header: ["Device", "Connector", "Pin", "Signal", "Net"],
                            rows: p.devices.flatMap { d in d.connectors.flatMap { c in c.pins.map { pin in
                                [t(d.id), t(c.id), t(pin.label), t(pin.signal ?? ""), t(netOf[SystemPin(.device(d.id, connector: c.id), pin.label).key] ?? "")]
                            } } }))
        sheets.append(.init(name: "Rule check", header: ["Severity", "Item", "Message"],
                            rows: issues.map { [t($0.severity.rawValue), t($0.subject), t($0.message)] }))
        return XLSXWriter(sheets: sheets)
    }
}
