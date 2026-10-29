import Foundation

/// Writes a real .xlsx workbook (Office Open XML in an uncompressed zip) without any dependencies.
public struct XLSXWriter {
    public enum Cell {
        case text(String)
        case number(Double)
    }

    public struct Sheet {
        public var name: String
        public var rows: [[Cell]]
        public init(name: String, header: [String], rows: [[Cell]]) {
            self.name = name
            self.rows = [header.map(Cell.text)] + rows
        }
    }

    public var sheets: [Sheet] = []
    public init(sheets: [Sheet] = []) { self.sheets = sheets }

    public func data() -> Data {
        var files: [(String, Data)] = []
        let names = uniqueSheetNames()
        files.append(("[Content_Types].xml", xml("""
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \(sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined())\
        </Types>
        """)))
        files.append(("_rels/.rels", xml("""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """)))
        files.append(("xl/workbook.xml", xml("""
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\
        \(names.enumerated().map { "<sheet name=\"\(esc($0.element))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined())\
        </sheets></workbook>
        """)))
        files.append(("xl/_rels/workbook.xml.rels", xml("""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined())\
        <Relationship Id="rId\(sheets.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        </Relationships>
        """)))
        // Style 1 = bold header.
        files.append(("xl/styles.xml", xml("""
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border/></borders>\
        <cellStyleXfs count="1"><xf/></cellStyleXfs>\
        <cellXfs count="2"><xf fontId="0"/><xf fontId="1" applyFont="1"/></cellXfs>\
        </styleSheet>
        """)))
        for (i, sheet) in sheets.enumerated() {
            var body = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            body += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" state=\"frozen\"/></sheetView></sheetViews><sheetData>"
            for (r, row) in sheet.rows.enumerated() {
                body += "<row r=\"\(r + 1)\">"
                for (c, cell) in row.enumerated() {
                    let ref = Self.column(c) + String(r + 1)
                    let style = r == 0 ? " s=\"1\"" : ""
                    switch cell {
                    case let .text(s): body += "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(esc(s))</t></is></c>"
                    case let .number(n): body += "<c r=\"\(ref)\"\(style)><v>\(n)</v></c>"
                    }
                }
                body += "</row>"
            }
            body += "</sheetData></worksheet>"
            files.append(("xl/worksheets/sheet\(i + 1).xml", xml(body)))
        }
        return ZipStore.archive(files)
    }

    static func column(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    private func uniqueSheetNames() -> [String] {
        var seen: Set<String> = []
        return sheets.map { s in
            var name = String(s.name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
            if name.isEmpty { name = "Sheet" }
            var candidate = name, k = 2
            while !seen.insert(candidate.lowercased()).inserted { candidate = String(name.prefix(28)) + " \(k)"; k += 1 }
            return candidate
        }
    }

    private func xml(_ s: String) -> Data { Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + s).utf8) }
    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Minimal zip writer using the "stored" method (no compression), which every zip reader accepts.
enum ZipStore {
    static func archive(_ files: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        for (name, data) in files {
            let nameData = Data(name.utf8)
            let crc = crc32(data)
            let offset = UInt32(out.count)
            out.append(le32(0x04034b50)); out.append(le16(20)); out.append(le16(0x0800)); out.append(le16(0))
            out.append(le16(0)); out.append(le16(0x21))   // time/date: 1980-01-01
            out.append(le32(crc)); out.append(le32(UInt32(data.count))); out.append(le32(UInt32(data.count)))
            out.append(le16(UInt16(nameData.count))); out.append(le16(0))
            out.append(nameData); out.append(data)

            central.append(le32(0x02014b50)); central.append(le16(20)); central.append(le16(20)); central.append(le16(0x0800))
            central.append(le16(0)); central.append(le16(0)); central.append(le16(0x21))
            central.append(le32(crc)); central.append(le32(UInt32(data.count))); central.append(le32(UInt32(data.count)))
            central.append(le16(UInt16(nameData.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0)); central.append(le32(offset))
            central.append(nameData)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32(0x06054b50)); out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(files.count))); out.append(le16(UInt16(files.count)))
        out.append(le32(UInt32(central.count))); out.append(le32(centralOffset)); out.append(le16(0))
        return out
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}

public extension HarnessAnalysis {
    /// All manufacturing tables as one workbook.
    func workbook(for h: Harness) -> XLSXWriter {
        let u = h.settings.units
        func n(_ v: Double?) -> XLSXWriter.Cell { v.map { .number((u.fromMM($0) * 100).rounded() / 100) } ?? .text("") }
        func t(_ s: String) -> XLSXWriter.Cell { .text(s) }
        var sheets: [XLSXWriter.Sheet] = []
        sheets.append(.init(name: "BOM", header: ["Category", "Internal PN", "MPN", "Manufacturer", "Description", "Qty", "Unit", "References", "Alternates", "Ext. price"],
                            rows: bom.map { l in [t(l.category), t(l.internalPN), t(l.mpn), t(l.manufacturer), t(l.description),
                                                  l.unit == .mm ? n(l.quantity) : .number(l.quantity), t(l.unit == .mm ? u.symbol : "ea"),
                                                  t(l.references.joined(separator: " ")), t(l.alternates.joined(separator: ", ")),
                                                  l.extendedPrice.map { .number($0) } ?? t("")] }))
        sheets.append(.init(name: "Cut list", header: ["Wire", "Kind", "Cable", "Twist", "Signal", "Size", "Colour", "Insulation", "Cut (\(u.symbol))",
                                                      "End A", "Terminal A", "Seal A", "Strip A", "End B", "Terminal B", "Seal B", "Strip B", "Marker"],
                            rows: cutList.map { r in [t(r.wireID), t(r.kind), t(r.cable), t(r.twist), t(r.signal), t(r.size), t(r.color), t(r.insulation),
                                                      n(r.cutLengthMM), t(r.endA), t(r.terminalA), t(r.sealA), n(r.stripA),
                                                      t(r.endB), t(r.terminalB), t(r.sealB), n(r.stripB), t(r.marker)] }))
        sheets.append(.init(name: "Wiring table", header: ["Connector", "Cavity", "Signal", "Wire", "Size", "Colour", "To", "Terminal", "Seal"],
                            rows: connectorTables.flatMap { tb in tb.rows.map { r in
                                [t(tb.connectorID), t(r.cavity), t(r.signal), t(r.wireID), t(r.size), t(r.color), t(r.destination), t(r.terminal), t(r.seal)] } }))
        sheets.append(.init(name: "Netlist", header: ["Net", "Pins", "Wires"],
                            rows: nets.map { [t($0.name), t($0.members.joined(separator: ", ")), t($0.wires.joined(separator: ", "))] }))
        sheets.append(.init(name: "Labels", header: ["Label", "Text", "Location", "Part"],
                            rows: labelList.map { [t($0.id), t($0.text), t($0.location), t($0.part)] }))
        sheets.append(.init(name: "Tools", header: ["Tool", "Kind", "Part number", "Used for"],
                            rows: toolList.map { [t($0.name), t($0.kind), t($0.partNumber), t($0.usedFor.joined(separator: "; "))] }))
        sheets.append(.init(name: "Notes", header: ["#", "Note", "Applies to"],
                            rows: h.notes.map { [.number(Double($0.id)), t($0.text), t($0.attachedTo.joined(separator: ", "))] }))
        sheets.append(.init(name: "Revisions", header: ["Rev", "Date", "Description", "By"],
                            rows: h.revisions.map { [t($0.rev), t($0.date), t($0.description), t($0.author)] }))
        return XLSXWriter(sheets: sheets)
    }
}
