import CoreGraphics
import CrimpCore
import Foundation

/// How a 1:1 formboard is printed.
public struct FormboardOptions: Hashable, Sendable {
    public enum Layout: String, CaseIterable, Hashable, Sendable {
        /// Ordinary sheets joined edge to edge (trimmed on crop marks, or glued over an overlap strip).
        case tiled
        /// One large sheet for a plotter or print shop; split into as few panels as the PDF page limit needs.
        case singleSheet
    }

    public var layout: Layout = .tiled
    public var paper: SheetSize = .letter
    public var portrait = false
    /// Strip printed on both neighbouring sheets so they can be glued over each other; 0 butts the sheets together.
    public var overlapMM: Double = 0
    /// First page: the whole harness with the sheet grid, so the pages can be laid out in order.
    public var assemblyMap = true

    public init() {}
}

/// The harness at true length and true bundle diameter, printed 1:1 for building on a formboard.
///
/// Tiled sheets have no border or title block, so the drawing runs right to the cut line and the sheets
/// join seamlessly: crop marks sit in the unprintable margin, alignment targets straddle every seam.
public enum Formboard {
    /// The largest page side a PDF allows (200 in).
    public static let maxSheetPoints: CGFloat = 14_400
    static let pointsPerMM = 72 / 25.4
    /// Unprintable margin most printers leave (¼ in).
    static let printMargin: CGFloat = 18

    struct Sheet {
        var size: CGSize
        var draw: (CGContext) -> Void
    }

    public static func make(_ h: Harness, options: FormboardOptions = FormboardOptions(), library: PartLibrary? = nil) -> Data {
        var scaled = h
        scaled.layoutToScale(pointsPerMM: pointsPerMM)
        let analysis = HarnessAnalysis(scaled)
        var opts = HarnessRenderer.Options()
        opts.bundleScale = CGFloat(pointsPerMM)     // bundles at true diameter
        opts.trueBundleWidth = true
        if let library { opts.photoURL = { library.photoURL(for: $0) } }
        let renderer = HarnessRenderer(harness: scaled, analysis: analysis, options: opts)
        let bounds = renderer.bounds.insetBy(dx: -36, dy: -36)
        let sheets = switch options.layout {
        case .tiled: tiled(h, renderer, bounds, options)
        case .singleSheet: single(h, renderer, bounds)
        }
        return render(sheets, title: "\(h.name) rev \(h.revision) formboard 1:1")
    }

    // MARK: Tiled sheets

    static func tiled(_ h: Harness, _ renderer: HarnessRenderer, _ bounds: CGRect, _ o: FormboardOptions) -> [Sheet] {
        let p = o.paper.points
        let page = o.portrait ? CGSize(width: p.height, height: p.width) : CGSize(width: p.width, height: p.height)
        let content = CGRect(origin: .zero, size: page).insetBy(dx: printMargin, dy: printMargin)
        let overlap = CGFloat(max(0, o.overlapMM) * pointsPerMM)
        let stepX = content.width - overlap, stepY = content.height - overlap
        let cols = max(1, Int(((bounds.width - overlap) / stepX).rounded(.up)))
        let rows = max(1, Int(((bounds.height - overlap) / stepY).rounded(.up)))
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        func name(_ r: Int, _ c: Int) -> String { "\(letters[r % letters.count])\(c + 1)" }
        func origin(_ r: Int, _ c: Int) -> CGPoint { CGPoint(x: bounds.minX + CGFloat(c) * stepX, y: bounds.minY + CGFloat(r) * stepY) }

        // Alignment targets on every seam, in model coordinates so neighbouring sheets print the same mark.
        var targets: [CGPoint] = []
        for c in 0..<cols - 1 {
            let x = origin(0, c + 1).x + overlap / 2
            for r in 0..<rows { for f in [0.25, 0.75] { targets.append(CGPoint(x: x, y: origin(r, 0).y + overlap / 2 + (stepY) * f)) } }
        }
        for r in 0..<rows - 1 {
            let y = origin(r + 1, 0).y + overlap / 2
            for c in 0..<cols { for f in [0.25, 0.75] { targets.append(CGPoint(x: origin(0, c).x + overlap / 2 + stepX * f, y: y)) } }
        }

        var sheets: [Sheet] = []
        if o.assemblyMap {
            sheets.append(Sheet(size: page) { cg in
                assemblyMap(cg, h: h, renderer: renderer, bounds: bounds, page: page, rows: rows, cols: cols, origin: origin, name: name,
                            stepX: stepX, stepY: stepY, overlap: overlap, options: o)
            })
        }
        let total = rows * cols
        for r in 0..<rows {
            for c in 0..<cols {
                let o0 = origin(r, c)
                let index = r * cols + c + 1
                sheets.append(Sheet(size: page) { cg in
                    cg.saveGState()
                    cg.clip(to: content)
                    cg.translateBy(x: content.minX - o0.x, y: content.minY - o0.y)
                    renderer.draw(in: cg)
                    for t in targets { target(t, cg) }
                    cg.restoreGState()
                    if overlap > 0 {
                        // Shade the strips the next sheet is glued over.
                        cg.setFillColor(CGColor(gray: 0, alpha: 0.06))
                        if c < cols - 1 { cg.fill(CGRect(x: content.maxX - overlap, y: content.minY, width: overlap, height: content.height)) }
                        if r < rows - 1 { cg.fill(CGRect(x: content.minX, y: content.maxY - overlap, width: content.width, height: overlap)) }
                    }
                    cropMarks(content, cg)
                    let ink = CGColor(gray: 0, alpha: 1), muted = CGColor(gray: 0.35, alpha: 1)
                    TextDraw.draw(name(r, c), in: cg, at: CGPoint(x: content.minX + 18, y: 4), size: 9, bold: true, color: ink)
                    TextDraw.draw("\(h.name) rev \(h.revision) · formboard 1:1 · sheet \(index) of \(total) · print at 100% (actual size)",
                                  in: cg, at: CGPoint(x: content.minX + 40, y: 5.5), size: 6.5, color: muted, maxWidth: content.width - 190)
                    var next: [String] = []
                    if c < cols - 1 { next.append("→ \(name(r, c + 1))") }
                    if r < rows - 1 { next.append("↓ \(name(r + 1, c))") }
                    TextDraw.draw(next.joined(separator: "   "), in: cg, at: CGPoint(x: content.maxX - 18, y: 5.5), size: 6.5, bold: true, color: ink, align: .right)
                    scaleBar(cg, at: CGPoint(x: content.minX + 18, y: content.maxY + 7))
                    let join = overlap > 0 ? "Glue the next sheet over the shaded strip, matching the targets"
                                           : "Trim on the crop marks and butt the sheets together, matching the targets"
                    TextDraw.draw(join, in: cg, at: CGPoint(x: content.maxX - 18, y: content.maxY + 5), size: 6.5, color: muted, align: .right,
                                  maxWidth: content.width - 360)
                })
            }
        }
        return sheets
    }

    static func assemblyMap(_ cg: CGContext, h: Harness, renderer: HarnessRenderer, bounds: CGRect, page: CGSize, rows: Int, cols: Int,
                            origin: (Int, Int) -> CGPoint, name: (Int, Int) -> String, stepX: CGFloat, stepY: CGFloat, overlap: CGFloat,
                            options o: FormboardOptions) {
        let ink = CGColor(gray: 0, alpha: 1), muted = CGColor(gray: 0.35, alpha: 1)
        let area = CGRect(origin: .zero, size: page).insetBy(dx: 36, dy: 36)
        TextDraw.draw("FORMBOARD 1:1 — ASSEMBLY MAP", in: cg, at: CGPoint(x: area.minX, y: area.minY), size: 14, bold: true, color: ink)
        TextDraw.draw("\(h.name) rev \(h.revision) · \(rows * cols) sheets (\(rows) × \(cols)) of \(o.paper.title)\(o.portrait ? " portrait" : " landscape")",
                      in: cg, at: CGPoint(x: area.minX, y: area.minY + 20), size: 9, color: muted)
        let steps = [
            "Print at 100% / Actual size — turn off “Fit to page”.",
            "Check the 100 mm bar on each sheet with a ruler before cutting.",
            overlap > 0 ? "Glue each sheet over the shaded strip of its neighbour, lining up the round targets."
                        : "Trim each sheet on its crop marks and butt the edges together, lining up the round targets.",
            "Lay the sheets out as below, then mount them on the board.",
        ]
        var y = area.minY + 40
        for (i, s) in steps.enumerated() {
            TextDraw.draw("\(i + 1). \(s)", in: cg, at: CGPoint(x: area.minX, y: y), size: 8.5, color: ink)
            y += 13
        }
        let map = CGRect(x: area.minX, y: y + 10, width: area.width, height: area.maxY - y - 10)
        let scale = min(map.width / bounds.width, map.height / bounds.height)
        cg.saveGState()
        cg.translateBy(x: map.midX - bounds.midX * scale, y: map.midY - bounds.midY * scale)
        cg.scaleBy(x: scale, y: scale)
        renderer.draw(in: cg)
        cg.setStrokeColor(CGColor(srgbRed: 0, green: 0.4, blue: 0.9, alpha: 1))
        cg.setLineWidth(1 / scale)
        for r in 0..<rows {
            for c in 0..<cols {
                let o0 = origin(r, c)
                let cell = CGRect(x: o0.x, y: o0.y, width: stepX + overlap, height: stepY + overlap)
                cg.stroke(cell)
                TextDraw.draw(name(r, c), in: cg, at: CGPoint(x: cell.minX + 6 / scale, y: cell.minY + 4 / scale), size: 11 / scale, bold: true,
                              color: CGColor(srgbRed: 0, green: 0.4, blue: 0.9, alpha: 1))
            }
        }
        cg.restoreGState()
    }

    // MARK: One large sheet

    static func single(_ h: Harness, _ renderer: HarnessRenderer, _ bounds: CGRect) -> [Sheet] {
        let strip: CGFloat = 46, pad: CGFloat = 36
        // Split along the long side only when the PDF page limit forces it.
        let maxW = maxSheetPoints - 2 * pad, maxH = maxSheetPoints - 2 * pad - strip
        let nx = max(1, Int((bounds.width / maxW).rounded(.up))), ny = max(1, Int((bounds.height / maxH).rounded(.up)))
        let panelW = bounds.width / CGFloat(nx), panelH = bounds.height / CGFloat(ny)
        let total = nx * ny
        var sheets: [Sheet] = []
        for r in 0..<ny {
            for c in 0..<nx {
                let o0 = CGPoint(x: bounds.minX + CGFloat(c) * panelW, y: bounds.minY + CGFloat(r) * panelH)
                let size = CGSize(width: panelW + 2 * pad, height: panelH + 2 * pad + strip)
                let index = r * nx + c + 1
                sheets.append(Sheet(size: size) { cg in
                    let content = CGRect(x: pad, y: pad, width: panelW, height: panelH)
                    cg.saveGState()
                    cg.clip(to: content)
                    cg.translateBy(x: content.minX - o0.x, y: content.minY - o0.y)
                    renderer.draw(in: cg)
                    cg.restoreGState()
                    if total > 1 { cropMarks(content, cg) }
                    let ink = CGColor(gray: 0, alpha: 1), muted = CGColor(gray: 0.35, alpha: 1)
                    let y = content.maxY + 16
                    cg.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
                    cg.setLineWidth(0.5)
                    cg.move(to: CGPoint(x: pad, y: y - 6)); cg.addLine(to: CGPoint(x: size.width - pad, y: y - 6)); cg.strokePath()
                    TextDraw.draw(h.name, in: cg, at: CGPoint(x: pad, y: y), size: 12, bold: true, color: ink)
                    let info = ["REV \(h.revision)", h.titleBlock.drawingNumber, "SCALE 1:1", "print at 100%",
                                total > 1 ? "panel \(index) of \(total)" : ""].filter { !$0.isEmpty }.joined(separator: "  ·  ")
                    TextDraw.draw(info, in: cg, at: CGPoint(x: pad, y: y + 16), size: 8, color: muted)
                    scaleBar(cg, at: CGPoint(x: size.width - pad - 100 * pointsPerMM, y: y + 2))
                })
            }
        }
        return sheets
    }

    // MARK: Marks

    /// Crop marks just outside each corner of the printed area, in the margin, never over the drawing.
    static func cropMarks(_ r: CGRect, _ cg: CGContext) {
        cg.setStrokeColor(CGColor(gray: 0, alpha: 1))
        cg.setLineWidth(0.4)
        let gap: CGFloat = 2, len: CGFloat = 12
        for (x, dx) in [(r.minX, -1.0), (r.maxX, 1.0)] {
            for (y, dy) in [(r.minY, -1.0), (r.maxY, 1.0)] {
                cg.move(to: CGPoint(x: x + dx * gap, y: y)); cg.addLine(to: CGPoint(x: x + dx * (gap + len), y: y))
                cg.move(to: CGPoint(x: x, y: y + dy * gap)); cg.addLine(to: CGPoint(x: x, y: y + dy * (gap + len)))
            }
        }
        cg.strokePath()
    }

    /// A round alignment target; it straddles a seam, so half prints on each sheet.
    static func target(_ p: CGPoint, _ cg: CGContext) {
        cg.setStrokeColor(CGColor(gray: 0, alpha: 0.8))
        cg.setLineWidth(0.5)
        cg.strokeEllipse(in: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
        cg.move(to: CGPoint(x: p.x - 11, y: p.y)); cg.addLine(to: CGPoint(x: p.x + 11, y: p.y))
        cg.move(to: CGPoint(x: p.x, y: p.y - 11)); cg.addLine(to: CGPoint(x: p.x, y: p.y + 11))
        cg.strokePath()
    }

    /// 100 mm bar for checking the print scale.
    static func scaleBar(_ cg: CGContext, at p: CGPoint) {
        let w = 100 * pointsPerMM
        cg.setFillColor(CGColor(gray: 0, alpha: 1))
        cg.fill(CGRect(x: p.x, y: p.y, width: w / 2, height: 3))
        cg.setStrokeColor(CGColor(gray: 0, alpha: 1))
        cg.setLineWidth(0.5)
        cg.stroke(CGRect(x: p.x, y: p.y, width: w, height: 3))
        TextDraw.draw("100 mm", in: cg, at: CGPoint(x: p.x + w + 4, y: p.y - 2), size: 6.5, bold: true, color: CGColor(gray: 0, alpha: 1))
    }

    static func render(_ sheets: [Sheet], title: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: sheets.first?.size ?? CGSize(width: 792, height: 612))
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let cg = CGContext(consumer: consumer, mediaBox: &box, [
                  kCGPDFContextTitle as String: title,
                  kCGPDFContextCreator as String: "Loomo",
              ] as CFDictionary) else { return Data() }
        for sheet in sheets {
            var media = CGRect(origin: .zero, size: sheet.size)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &media, count: MemoryLayout<CGRect>.size) as CFData] as CFDictionary
            cg.beginPDFPage(info)
            cg.translateBy(x: 0, y: sheet.size.height)
            cg.scaleBy(x: 1, y: -1)
            sheet.draw(cg)
            cg.endPDFPage()
        }
        cg.closePDF()
        return data as Data
    }
}

public extension PDFDrawingSet {
    /// The harness laid out at true length and tiled across sheets at 1:1, for a production formboard.
    static func formboard(_ h: Harness, options: FormboardOptions = FormboardOptions(), library: PartLibrary? = nil) -> Data {
        Formboard.make(h, options: options, library: library)
    }
}
