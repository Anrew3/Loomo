import CoreGraphics
import CrimpCore
import Foundation

/// Which pages a PDF export contains, in order.
public enum DrawingPage: String, CaseIterable, Codable, Sendable, Identifiable {
    case harness, connectorFaces, connectorTables, wiringTable, cutList, bom, netlist, labels, tools, notes
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .harness: "Harness drawing"
        case .connectorFaces: "Connector faces"
        case .connectorTables: "Connection tables"
        case .wiringTable: "Wiring table"
        case .cutList: "Cut list"
        case .bom: "Bill of materials"
        case .netlist: "Netlist"
        case .labels: "Labels"
        case .tools: "Tools"
        case .notes: "Notes & revisions"
        }
    }
}

/// Builds the manufacturing PDF in the style of an engineering drawing: a zoned border, a sheet heading,
/// a full title block on every sheet, and tables that flow onto extra sheets.
public final class PDFDrawingSet {
    let h: Harness
    let a: HarnessAnalysis
    let pageSize: CGSize
    /// Space outside the border (most printers can't print to the edge).
    let margin: CGFloat = 20
    /// The band between the outer and inner border lines holding zone letters and numbers.
    let zoneBand: CGFloat = 12
    let titleBlockHeight: CGFloat = 78
    let headingHeight: CGFloat = 30

    /// Title-block data for a page; pages from embedded harness drawing sets keep their own.
    struct FrameInfo {
        var name: String
        var revision: String
        var titleBlock: TitleBlock
    }

    struct Page {
        var frame: FrameInfo
        var title: String
        var draw: (CGContext, CGRect) -> Void
    }

    var pages: [Page] = []
    var frame: FrameInfo

    /// Library used for shared connector face layouts and custom part photos.
    var library: PartLibrary?
    /// Put the BOM, notes, revisions and coverings legend beside the drawing on the harness sheet.
    public var tablesOnDrawingSheet = true

    public init(harness: Harness, analysis: HarnessAnalysis, library: PartLibrary? = nil) {
        self.library = library
        h = harness
        a = analysis
        let s = harness.titleBlock.pagePoints
        pageSize = CGSize(width: s.width, height: s.height)
        frame = FrameInfo(name: harness.name, revision: harness.revision, titleBlock: harness.titleBlock)
    }

    public static func make(_ h: Harness, analysis: HarnessAnalysis? = nil, pages: [DrawingPage] = DrawingPage.allCases,
                            library: PartLibrary? = nil, tablesOnDrawingSheet: Bool = true) -> Data {
        Signposts.interval("PDF drawing set") {
            let set = PDFDrawingSet(harness: h, analysis: analysis ?? HarnessAnalysis(h), library: library)
            set.tablesOnDrawingSheet = tablesOnDrawingSheet
            for p in pages { set.add(p) }
            return set.render()
        }
    }

    // MARK: Sheet geometry

    var outerBorder: CGRect { CGRect(origin: .zero, size: pageSize).insetBy(dx: margin, dy: margin) }
    var innerBorder: CGRect { outerBorder.insetBy(dx: zoneBand, dy: zoneBand) }
    var titleBlockRect: CGRect {
        let inner = innerBorder
        let w = min(470, inner.width * 0.6)
        return CGRect(x: inner.maxX - w, y: inner.maxY - titleBlockHeight, width: w, height: titleBlockHeight)
    }

    /// The area pages draw into: below the heading, above the title block.
    var contentRect: CGRect {
        let inner = innerBorder.insetBy(dx: 10, dy: 0)
        let top = inner.minY + headingHeight + 8
        return CGRect(x: inner.minX, y: top, width: inner.width, height: titleBlockRect.minY - 10 - top)
    }

    // MARK: Pages

    public func add(_ page: DrawingPage) {
        switch page {
        case .harness:
            addHarnessSheet()
        case .connectorFaces:
            let faces = h.connectors.filter { !$0.kind.isLooseTerminal && $0.kind != .loosePins }.map { c -> FaceDrawing in
                var o = FaceDrawingOptions()
                o.title = [c.id, c.name, c.part?.mpn].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                return h.faceDrawing(for: c, layout: h.faceLayout(for: c, library: library), options: o)
            }
            // Two by two per sheet, each face scaled to fit its cell.
            for start in stride(from: 0, to: faces.count, by: 4) {
                let chunk = Array(faces[start..<min(start + 4, faces.count)])
                pages.append(Page(frame: frame, title: "Connector faces", draw: { cg, rect in
                    let cellW = rect.width / 2, cellH = rect.height / 2
                    for (i, d) in chunk.enumerated() {
                        let cell = CGRect(x: rect.minX + CGFloat(i % 2) * cellW, y: rect.minY + CGFloat(i / 2) * cellH, width: cellW, height: cellH)
                        let box = cell.insetBy(dx: 6, dy: 6)
                        cg.setStrokeColor(Self.rule)
                        cg.setLineWidth(0.5)
                        cg.stroke(box)
                        let scale = min((box.width - 16) / d.width, (box.height - 16) / d.height, 1.2)
                        cg.saveGState()
                        cg.translateBy(x: box.midX - d.width * scale / 2, y: box.midY - d.height * scale / 2)
                        cg.scaleBy(x: scale, y: scale)
                        FaceRenderer.draw(d, in: cg)
                        cg.restoreGState()
                    }
                }))
            }
        case .connectorTables:
            var groups = a.connectorTables.compactMap { t -> TableGroup? in
                let rows = t.rows.map { [$0.cavity, $0.conductor, $0.wireID, $0.size, $0.destination, $0.terminal, $0.seal, $0.twistedWith] }
                guard !rows.isEmpty else { return nil }
                var title = t.title
                if let c = h.connector(t.connectorID) {
                    if let m = c.mate { title += "  —  mates with \(m)" }
                    if !c.boxItems.isEmpty {
                        title += "  —  " + c.boxItems.map { "\($0.id) \($0.rating ?? $0.kind.title) (\($0.cavities.joined(separator: "–")))" }.joined(separator: ", ")
                    }
                }
                return TableGroup(title, ["Pin", "Conductor", "Wire", "Size", "To", "Contact", "Seal", "Twisted with"],
                                  [0.06, 0.2, 0.07, 0.09, 0.14, 0.17, 0.15, 0.12], rows)
            }
            groups += a.spliceTables.filter { !$0.rows.isEmpty }.map { t in
                TableGroup(t.title, ["Wire", "Conductor", "Size", "To", "Splice part", "Twisted with"], [0.08, 0.24, 0.1, 0.18, 0.24, 0.16],
                           t.rows.map { [$0.wireID, $0.conductor, $0.size, $0.destination, $0.terminal, $0.twistedWith] })
            }
            table("Connection tables", groups: groups.map(\.tuple))
        case .wiringTable:
            let twistOf = Dictionary(h.twists.flatMap { t in t.wireIDs.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
            table("Wiring table", groups: [(nil, ["Wire", "Conductor", "From", "To", "Size", "Insulation", "Length", "Cable", "Twisted with"],
                                             [0.06, 0.18, 0.11, 0.11, 0.09, 0.09, 0.12, 0.1, 0.14],
                                             h.wires.map { w in
                                                 [w.id, HarnessAnalysis.conductorName(w), w.from.description, w.to.description, w.size.description,
                                                  w.insulation, h.settings.units.format(a.routes[w.id]?.lengthMM), w.cableID ?? "",
                                                  twistOf[w.id].map { $0.wireIDs.filter { $0 != w.id }.joined(separator: ", ") } ?? ""]
                                             })])
        case .cutList:
            let u = h.settings.units
            table("Cut list", groups: [(nil, ["Wire", "Kind", "Size", "Colour", "Cut", "End A", "Terminal A", "Strip A", "End B", "Terminal B", "Strip B", "Marker"],
                                          [0.06, 0.08, 0.08, 0.07, 0.09, 0.08, 0.13, 0.06, 0.08, 0.13, 0.06, 0.08],
                                          a.cutList.map { r in
                                              [r.wireID, r.kind, r.size, r.color, u.format(r.cutLengthMM), r.endA, r.terminalA,
                                               r.stripA.map { u.format($0, decimals: 2) } ?? "", r.endB, r.terminalB,
                                               r.stripB.map { u.format($0, decimals: 2) } ?? "", r.marker]
                                          })])
        case .bom:
            let u = h.settings.units
            table("Bill of materials", groups: [(nil, ["Item", "Type", "Qty", "Internal PN", "MPN", "Manufacturer", "Description", "Used on"],
                                                    [0.05, 0.1, 0.09, 0.1, 0.14, 0.13, 0.22, 0.17],
                                                    a.bom.map { l in
                                                        [String(l.item), l.category,
                                                         l.unit == .mm ? u.format(l.quantity) : String(format: "%g", l.quantity),
                                                         l.internalPN, l.mpn, l.manufacturer, l.description, l.references.joined(separator: " ")]
                                                    })])
        case .netlist:
            table("Netlist", groups: [(nil, ["Net", "Pins", "Wires"], [0.2, 0.5, 0.3],
                                         a.nets.map { [$0.name, $0.members.joined(separator: ", "), $0.wires.joined(separator: ", ")] })])
        case .labels:
            table("Labels", groups: [(nil, ["Label", "Text", "Location", "Part"], [0.12, 0.38, 0.3, 0.2],
                                        a.labelList.map { [$0.id, $0.text, $0.location, $0.part] })])
        case .tools:
            table("Tools", groups: [(nil, ["Tool", "Kind", "Part number", "Used for"], [0.2, 0.15, 0.2, 0.45],
                                       a.toolList.map { [$0.name, $0.kind, $0.partNumber, $0.usedFor.joined(separator: "; ")] })])
        case .notes:
            table("Notes & revisions", groups: [
                ("Notes", ["#", "Note", "Applies to"], [0.06, 0.74, 0.2], h.notes.map { [String($0.id), $0.text, $0.attachedTo.joined(separator: ", ")] }),
                ("Revisions", ["Rev", "Date", "Description", "By"], [0.08, 0.14, 0.6, 0.18], h.revisions.map { [$0.rev, $0.date, $0.description, $0.author] }),
            ])
        }
    }

    struct TableGroup {
        var tuple: (String?, [String], [CGFloat], [[String]])
        init(_ title: String?, _ header: [String], _ widths: [CGFloat], _ rows: [[String]]) { tuple = (title, header, widths, rows) }
    }

    /// The harness sheet: the drawing, with revisions, notes, a coverings legend and the BOM in a column beside it.
    func addHarnessSheet() {
        var opts = HarnessRenderer.Options()
        if let library { opts.photoURL = { library.photoURL(for: $0) } }
        let renderer = HarnessRenderer(harness: h, analysis: a, options: opts)
        let side = tablesOnDrawingSheet && (!h.revisions.isEmpty || !h.notes.isEmpty || !h.coverings.isEmpty || !a.bom.isEmpty)
        pages.append(Page(frame: frame, title: "Harness drawing", draw: { [h, a] cg, rect in
            let columnWidth: CGFloat = side ? min(290, rect.width * 0.28) : 0
            let b = renderer.bounds
            // The tables column only takes the height it needs; the drawing uses the whole sheet when it fits
            // beside or under the column, the way a drawing sheet's BOM sits in a corner.
            let columnHeight = side ? min(rect.height, self.sideColumnHeight(width: columnWidth)) : 0
            let column = CGRect(x: rect.maxX - columnWidth, y: rect.minY, width: columnWidth, height: columnHeight)
            func fit(_ area: CGRect) -> (CGFloat, CGRect) {
                let s = min(area.width / b.width, area.height / b.height, 1.25)
                let w = b.width * s, hgt = b.height * s
                return (s, CGRect(x: area.midX - w / 2, y: area.midY - hgt / 2, width: w, height: hgt))
            }
            var best = fit(rect)
            if side && best.1.insetBy(dx: -6, dy: -6).intersects(column) {
                let beside = fit(CGRect(x: rect.minX, y: rect.minY, width: rect.width - columnWidth - 16, height: rect.height))
                let under = fit(CGRect(x: rect.minX, y: column.maxY + 14, width: rect.width, height: rect.maxY - column.maxY - 14))
                best = under.0 > beside.0 ? under : beside
                // Shifting left can free the column even at full size.
                let full = fit(rect)
                let shifted = full.1.offsetBy(dx: max(rect.minX, full.1.minX - (full.1.maxX - column.minX + 16)) - full.1.minX, dy: 0)
                if !shifted.insetBy(dx: -6, dy: -6).intersects(column), shifted.minX >= rect.minX - 0.5, full.0 > best.0 { best = (full.0, shifted) }
            }
            let (scale, placed) = best
            cg.saveGState()
            cg.clip(to: rect)
            cg.translateBy(x: placed.minX - b.minX * scale, y: placed.minY - b.minY * scale)
            cg.scaleBy(x: scale, y: scale)
            renderer.draw(in: cg)
            cg.restoreGState()
            guard side else { return }

            let col = CGRect(x: rect.maxX - columnWidth, y: rect.minY, width: columnWidth, height: rect.height)
            cg.setStrokeColor(Self.rule)
            cg.setLineWidth(0.5)
            cg.move(to: CGPoint(x: col.minX - 7, y: col.minY)); cg.addLine(to: CGPoint(x: col.minX - 7, y: col.minY + columnHeight)); cg.strokePath()
            var y = col.minY
            let w = col.width
            func fits(_ rows: Int) -> Bool { y + CGFloat(rows + 1) * 11 + 18 < col.maxY }

            if !h.revisions.isEmpty, fits(h.revisions.count) {
                y = self.sectionTitle("REVISIONS", cg, x: col.minX, y: y)
                y = self.miniTable(cg, x: col.minX, y: y, widths: [0.12, 0.24, 0.48, 0.16].map { $0 * w }, header: ["REV", "DATE", "DESCRIPTION", "BY"],
                                   rows: h.revisions.map { [$0.rev, $0.date, $0.description, $0.author] }, rowHeight: 11) + 12
            }
            if !h.notes.isEmpty {
                y = self.sectionTitle("NOTES", cg, x: col.minX, y: y)
                for n in h.notes where y < col.maxY - 30 {
                    TextDraw.draw("\(n.id).", in: cg, at: CGPoint(x: col.minX, y: y), size: 7.5, bold: true, color: Self.ink)
                    y = self.wrapped(n.text, in: cg, x: col.minX + 14, y: y, width: w - 14, size: 7.5) + 3
                }
                y += 9
            }
            if !h.coverings.isEmpty, fits(h.coverings.count) {
                y = self.sectionTitle("COVERINGS", cg, x: col.minX, y: y)
                let widths = [0.1, 0.14, 0.26, 0.5].map { $0 * w }
                let top = y
                y = self.miniTable(cg, x: col.minX, y: y, widths: widths, header: ["", "ID", "TYPE", "PART / DESCRIPTION"],
                                   rows: h.coverings.map { c in ["", c.id + (a.itemNumbers[c.id].map { " [\($0)]" } ?? ""), c.kind.title,
                                                                  c.part.map { [$0.mpn, $0.description].compactMap { $0 }.joined(separator: " ") } ?? ""] },
                                   rowHeight: 11)
                // Swatches in the first column, drawn like the covering on the drawing.
                for (i, c) in h.coverings.enumerated() {
                    let r = CGRect(x: col.minX + 4, y: top + CGFloat(i + 1) * 11 + 3, width: widths[0] - 8, height: 5)
                    cg.setFillColor(color(c.colorHex, alpha: 0.6))
                    cg.fill(r)
                }
                y += 12
            }
            if !a.bom.isEmpty {
                y = self.sectionTitle("BILL OF MATERIALS", cg, x: col.minX, y: y)
                let room = max(0, Int((col.maxY - y - 11 - 14) / 11))
                let shown = Array(a.bom.prefix(room))
                y = self.miniTable(cg, x: col.minX, y: y, widths: [0.1, 0.17, 0.28, 0.45].map { $0 * w }, header: ["ITEM", "QTY", "PART NO.", "DESCRIPTION"],
                                   rows: shown.map { l in
                                       [String(l.item), l.unit == .mm ? h.settings.units.format(l.quantity) : String(format: "%g", l.quantity),
                                        l.internalPN.isEmpty ? l.mpn : l.internalPN, l.description]
                                   }, rowHeight: 11)
                if shown.count < a.bom.count {
                    TextDraw.draw("\(a.bom.count - shown.count) more items on the Bill of Materials sheet", in: cg,
                                  at: CGPoint(x: col.minX, y: y + 3), size: 6.5, color: Self.muted)
                }
            }
        }))
    }

    /// Height the revisions, notes, coverings and BOM need in the side column.
    func sideColumnHeight(width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        if !h.revisions.isEmpty { y += 13 + CGFloat(h.revisions.count + 1) * 11 + 12 }
        if !h.notes.isEmpty {
            y += 13 + 9
            for n in h.notes {
                let words = TextDraw.width(n.text, size: 7.5)
                y += (ceil(words / max(width - 14, 40)) * 10.5) + 3
            }
        }
        if !h.coverings.isEmpty { y += 13 + CGFloat(h.coverings.count + 1) * 11 + 12 }
        if !a.bom.isEmpty { y += 13 + CGFloat(a.bom.count + 1) * 11 + 14 }
        return y
    }

    func sectionTitle(_ s: String, _ cg: CGContext, x: CGFloat, y: CGFloat) -> CGFloat {
        TextDraw.draw(s, in: cg, at: CGPoint(x: x, y: y), size: 8, bold: true, color: Self.ink)
        return y + 13
    }

    /// Lays out one or more titled tables, starting new pages as they fill.
    func table(_ pageTitle: String, groups: [(String?, [String], [CGFloat], [[String]])]) {
        let rowH: CGFloat = 13, area = contentRect
        let titleH: CGFloat = 20
        var chunks: [[(String?, [String], [CGFloat], [[String]])]] = [[]]
        var y: CGFloat = 0
        for (title, header, widths, rows) in groups {
            var remaining = rows[...]
            var first = true
            repeat {
                let need = (title != nil ? titleH : 0) + rowH * 2
                if y + need > area.height, !chunks[chunks.count - 1].isEmpty { chunks.append([]); y = 0 }
                let fit = max(1, Int((area.height - y - (title != nil ? titleH : 0) - rowH) / rowH))
                let slice = Array(remaining.prefix(fit))
                remaining = remaining.dropFirst(slice.count)
                chunks[chunks.count - 1].append((first ? title : title.map { $0 + " (continued)" }, header, widths, slice))
                y += (title != nil ? titleH : 0) + rowH * CGFloat(slice.count + 1) + 14
                first = false
                if !remaining.isEmpty { chunks.append([]); y = 0 }
            } while !remaining.isEmpty
        }
        for chunk in chunks where !chunk.isEmpty {
            pages.append(Page(frame: frame, title: pageTitle, draw: { cg, rect in
                var y = rect.minY
                for (title, header, widths, rows) in chunk {
                    if let title {
                        TextDraw.draw(title, in: cg, at: CGPoint(x: rect.minX, y: y + 2), size: 9.5, bold: true, color: Self.ink, maxWidth: rect.width)
                        y += titleH
                    }
                    let w = widths.map { $0 * rect.width }
                    y = self.miniTable(cg, x: rect.minX, y: y, widths: w, header: header, rows: rows, rowHeight: rowH) + 14
                }
            }))
        }
    }

    // MARK: Rendering

    static let ink = CGColor(gray: 0.08, alpha: 1)
    static let muted = CGColor(gray: 0.42, alpha: 1)
    static let rule = CGColor(gray: 0.62, alpha: 1)
    static let headerFill = CGColor(srgbRed: 0.17, green: 0.2, blue: 0.25, alpha: 1)
    static let zebra = CGColor(srgbRed: 0.955, green: 0.963, blue: 0.972, alpha: 1)
    var ink: CGColor { Self.ink }

    public func render(scaleNote: String = "NTS") -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let cg = CGContext(consumer: consumer, mediaBox: &box, [
                  kCGPDFContextTitle as String: "\(frame.name) rev \(frame.revision)",
                  kCGPDFContextCreator as String: "Loomo",
              ] as CFDictionary) else { return Data() }
        for (i, page) in pages.enumerated() {
            cg.beginPDFPage(nil)
            cg.translateBy(x: 0, y: pageSize.height)
            cg.scaleBy(x: 1, y: -1)
            drawFrame(cg, frame: page.frame, title: page.title, sheet: i + 1, of: pages.count, scaleNote: scaleNote)
            page.draw(cg, contentRect)
            cg.endPDFPage()
        }
        cg.closePDF()
        return data as Data
    }

    func drawFrame(_ cg: CGContext, frame info: FrameInfo, title: String, sheet: Int, of total: Int, scaleNote: String) {
        let outer = outerBorder, inner = innerBorder
        cg.setStrokeColor(ink)
        cg.setLineWidth(1.4)
        cg.stroke(inner)
        cg.setLineWidth(0.5)
        cg.stroke(outer)

        // Zones: numbers across the top and bottom, letters down the sides, like a standard drawing frame.
        let cols = max(4, Int((inner.width / 110).rounded())), rows = max(3, Int((inner.height / 110).rounded()))
        let zw = inner.width / CGFloat(cols), zh = inner.height / CGFloat(rows)
        cg.setLineWidth(0.5)
        for i in 0..<cols {
            let x = inner.minX + CGFloat(i) * zw
            if i > 0 {
                for (y0, y1) in [(outer.minY, inner.minY), (inner.maxY, outer.maxY)] {
                    cg.move(to: CGPoint(x: x, y: y0)); cg.addLine(to: CGPoint(x: x, y: y1))
                }
            }
            let label = String(cols - i)
            TextDraw.draw(label, in: cg, at: CGPoint(x: x + zw / 2, y: outer.minY + 2.5), size: 6.5, color: Self.muted, align: .center)
            TextDraw.draw(label, in: cg, at: CGPoint(x: x + zw / 2, y: inner.maxY + 2.5), size: 6.5, color: Self.muted, align: .center)
        }
        let letters = Array("ABCDEFGHJKLMNPRSTUVWXYZ")
        for j in 0..<rows {
            let y = inner.minY + CGFloat(j) * zh
            if j > 0 {
                for (x0, x1) in [(outer.minX, inner.minX), (inner.maxX, outer.maxX)] {
                    cg.move(to: CGPoint(x: x0, y: y)); cg.addLine(to: CGPoint(x: x1, y: y))
                }
            }
            let label = String(letters[min(rows - 1 - j, letters.count - 1)])
            TextDraw.draw(label, in: cg, at: CGPoint(x: outer.minX + zoneBand / 2, y: y + zh / 2 - 4), size: 6.5, color: Self.muted, align: .center)
            TextDraw.draw(label, in: cg, at: CGPoint(x: inner.maxX + zoneBand / 2, y: y + zh / 2 - 4), size: 6.5, color: Self.muted, align: .center)
        }
        cg.strokePath()

        // Sheet heading: what this sheet is, and which drawing it belongs to.
        let hx = inner.minX + 10, hy = inner.minY + 9
        TextDraw.draw(title.uppercased(), in: cg, at: CGPoint(x: hx, y: hy), size: 12, bold: true, color: ink, maxWidth: inner.width * 0.6)
        let ref = [info.titleBlock.drawingNumber, info.name, "REV \(info.revision)"].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        TextDraw.draw(ref, in: cg, at: CGPoint(x: inner.maxX - 10, y: hy + 3), size: 8, color: Self.muted, align: .right, maxWidth: inner.width * 0.35)
        cg.setStrokeColor(Self.rule)
        cg.setLineWidth(0.5)
        cg.move(to: CGPoint(x: inner.minX + 10, y: inner.minY + headingHeight))
        cg.addLine(to: CGPoint(x: inner.maxX - 10, y: inner.minY + headingHeight))
        cg.strokePath()

        drawTitleBlock(cg, info: info, sheet: sheet, of: total, scaleNote: scaleNote)
    }

    func drawTitleBlock(_ cg: CGContext, info: FrameInfo, sheet: Int, of total: Int, scaleNote: String) {
        let tb = info.titleBlock
        let r = titleBlockRect
        cg.setFillColor(CGColor(gray: 1, alpha: 1))
        cg.fill(r)
        cg.setStrokeColor(ink)
        cg.setLineWidth(1.2)
        cg.stroke(r)

        // Left: company band with logo; right: the title. Then two rows of fields.
        let topH: CGFloat = 32, rowH = (r.height - topH) / 2
        let leftW: CGFloat = min(150, r.width * 0.33)
        let company = CGRect(x: r.minX, y: r.minY, width: leftW, height: topH)
        cg.setFillColor(Self.headerFill)
        cg.fill(company)
        var textX = company.minX + 8
        if let logo = tb.logoPNG.flatMap(HarnessRenderer.cgImage) {
            let box = CGRect(x: company.minX + 5, y: company.minY + 4, width: 40, height: topH - 8)
            let aspect = CGFloat(logo.width) / CGFloat(max(logo.height, 1))
            var fit = box
            if box.width / box.height > aspect { fit.size.width = box.height * aspect } else { fit.size.height = box.width / aspect }
            cg.setFillColor(CGColor(gray: 1, alpha: 1))
            cg.fill(fit.insetBy(dx: -2, dy: -2))
            cg.saveGState()
            cg.translateBy(x: fit.minX, y: fit.maxY)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(logo, in: CGRect(origin: .zero, size: fit.size))
            cg.restoreGState()
            textX = fit.maxX + 8
        }
        let white = CGColor(gray: 1, alpha: 1)
        TextDraw.draw(tb.company.isEmpty ? "—" : tb.company.uppercased(), in: cg, at: CGPoint(x: textX, y: company.minY + 6), size: 9, bold: true,
                      color: white, maxWidth: company.maxX - textX - 6)
        TextDraw.draw("WIRE HARNESS DRAWING", in: cg, at: CGPoint(x: textX, y: company.minY + 18), size: 6, color: CGColor(gray: 0.78, alpha: 1),
                      maxWidth: company.maxX - textX - 6)

        let titleCell = CGRect(x: company.maxX, y: r.minY, width: r.width - leftW, height: topH)
        label("TITLE", cg, titleCell)
        TextDraw.draw(info.name, in: cg, at: CGPoint(x: titleCell.minX + 6, y: titleCell.minY + 11), size: 13, bold: true, color: ink,
                      maxWidth: titleCell.width - 12)

        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let row1: [(String, String, CGFloat, Bool)] = [("DWG NO.", tb.drawingNumber, 0.38, true), ("REV", info.revision, 0.12, true),
                                                        ("SHEET", "\(sheet) OF \(total)", 0.16, false), ("SCALE", scaleNote, 0.14, false),
                                                        ("SIZE", tb.sheetSize.title, 0.2, false)]
        let row2: [(String, String, CGFloat, Bool)] = [("DRAWN", tb.drawnBy, 0.25, false), ("CHECKED", tb.checkedBy, 0.25, false),
                                                        ("APPROVED", tb.approvedBy, 0.25, false), ("DATE", date, 0.25, false)]
        cg.setLineWidth(0.6)
        cg.setStrokeColor(ink)
        for (ri, row) in [row1, row2].enumerated() {
            let y = r.minY + topH + CGFloat(ri) * rowH
            cg.move(to: CGPoint(x: r.minX, y: y)); cg.addLine(to: CGPoint(x: r.maxX, y: y)); cg.strokePath()
            var x = r.minX
            for (i, cell) in row.enumerated() {
                let w = cell.2 * r.width
                let rect = CGRect(x: x, y: y, width: w, height: rowH)
                if i > 0 { cg.move(to: CGPoint(x: x, y: y)); cg.addLine(to: CGPoint(x: x, y: y + rowH)); cg.strokePath() }
                label(cell.0, cg, rect)
                TextDraw.draw(cell.1, in: cg, at: CGPoint(x: x + 5, y: y + 9.5), size: cell.3 ? 10 : 8, bold: cell.3, color: ink, maxWidth: w - 10)
                x += w
            }
        }
        cg.move(to: CGPoint(x: company.maxX, y: r.minY)); cg.addLine(to: CGPoint(x: company.maxX, y: r.minY + topH)); cg.strokePath()
    }

    func label(_ s: String, _ cg: CGContext, _ cell: CGRect) {
        TextDraw.draw(s, in: cg, at: CGPoint(x: cell.minX + 5, y: cell.minY + 2.5), size: 5.5, color: Self.muted)
    }

    @discardableResult
    func miniTable(_ cg: CGContext, x: CGFloat, y: CGFloat, widths: [CGFloat], header: [String], rows: [[String]], rowHeight: CGFloat = 13) -> CGFloat {
        let total = widths.reduce(0, +)
        let size: CGFloat = rowHeight >= 13 ? 7.5 : 6.8
        // Dark header row with white text.
        cg.setFillColor(Self.headerFill)
        cg.fill(CGRect(x: x, y: y, width: total, height: rowHeight))
        var xx = x
        for (ci, text) in header.enumerated() where ci < widths.count {
            TextDraw.draw(text.uppercased(), in: cg, at: CGPoint(x: xx + 4, y: y + (rowHeight - size) / 2 - 0.5), size: size - 0.7, bold: true,
                          color: CGColor(gray: 1, alpha: 1), maxWidth: widths[ci] - 8)
            xx += widths[ci]
        }
        var yy = y + rowHeight
        for (ri, row) in rows.enumerated() {
            if ri % 2 == 1 {
                cg.setFillColor(Self.zebra)
                cg.fill(CGRect(x: x, y: yy, width: total, height: rowHeight))
            }
            xx = x
            for (ci, text) in row.enumerated() where ci < widths.count {
                TextDraw.draw(text, in: cg, at: CGPoint(x: xx + 4, y: yy + (rowHeight - size) / 2 - 0.5), size: size, color: ink, maxWidth: widths[ci] - 8)
                xx += widths[ci]
            }
            yy += rowHeight
            cg.setStrokeColor(CGColor(gray: 0.84, alpha: 1))
            cg.setLineWidth(0.3)
            cg.move(to: CGPoint(x: x, y: yy)); cg.addLine(to: CGPoint(x: x + total, y: yy)); cg.strokePath()
        }
        // Column rules and the outline.
        cg.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
        cg.setLineWidth(0.3)
        xx = x
        for w in widths.dropLast() {
            xx += w
            cg.move(to: CGPoint(x: xx, y: y + rowHeight)); cg.addLine(to: CGPoint(x: xx, y: yy)); cg.strokePath()
        }
        cg.setStrokeColor(CGColor(gray: 0.3, alpha: 1))
        cg.setLineWidth(0.7)
        cg.stroke(CGRect(x: x, y: y, width: total, height: yy - y))
        return yy
    }

    func wrapped(_ text: String, in cg: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat) -> CGFloat {
        var yy = y, line = ""
        for word in text.split(separator: " ") {
            let candidate = line.isEmpty ? String(word) : line + " " + word
            if TextDraw.width(candidate, size: size) > width, !line.isEmpty {
                TextDraw.draw(line, in: cg, at: CGPoint(x: x, y: yy), size: size, color: ink)
                yy += size + 3
                line = String(word)
            } else { line = candidate }
        }
        if !line.isEmpty { TextDraw.draw(line, in: cg, at: CGPoint(x: x, y: yy), size: size, color: ink); yy += size + 3 }
        return yy
    }
}
