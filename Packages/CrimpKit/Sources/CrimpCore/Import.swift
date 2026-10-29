import Foundation

public enum CSV {
    /// RFC 4180 parsing: quoted fields, doubled quotes, commas/newlines inside quotes. Also accepts tabs or semicolons.
    public static func parse(_ text: String) -> [[String]] {
        let delimiter: Character = {
            let firstLine = text.prefix { $0 != "\n" }
            let counts: [(Character, Int)] = [",", "\t", ";"].map { d in (d, firstLine.filter { $0 == d }.count) }
            return counts.max { $0.1 < $1.1 }!.1 > 0 ? counts.max { $0.1 < $1.1 }!.0 : ","
        }()
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var it = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() {
                        if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else if c != "\r" {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    public static func escape(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}

public struct ImportReport: Sendable {
    public var wiresAdded = 0
    public var connectorsCreated: [EntityID] = []
    public var skippedRows: [String] = []
    public init() {}
}

public extension Harness {
    /// Imports a from-to wire list (CSV/TSV saved from Excel).
    ///
    /// Recognised headers (case-insensitive): Wire/ID, Signal/Net, From + From Pin (or From as "C1:3"),
    /// To + To Pin, Gauge/AWG/Size/mm2, Color/Colour, Insulation/Type, Length, Cable, Marker.
    /// Missing connectors are created with enough cavities; endpoints starting with "SP" become splices.
    @discardableResult
    mutating func importWireList(csv text: String) -> ImportReport {
        var report = ImportReport()
        let rows = CSV.parse(text)
        guard let header = rows.first else { return report }
        let cols = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ names: String...) -> Int? { cols.firstIndex { names.contains($0) } }
        let iWire = col("wire", "id", "wire id", "wire #"), iSignal = col("signal", "net", "function")
        let iFrom = col("from", "from connector", "connector a", "end a"), iFromPin = col("from pin", "from cavity", "pin a", "cavity a")
        let iTo = col("to", "to connector", "connector b", "end b"), iToPin = col("to pin", "to cavity", "pin b", "cavity b")
        let iSize = col("gauge", "awg", "size", "mm2", "mm²", "csa"), iColor = col("color", "colour")
        let iIns = col("insulation", "type", "wire type"), iLen = col("length", "length (mm)", "len")
        let iCable = col("cable"), iMarker = col("marker", "label")

        func endpoint(_ conn: String, _ pin: String?) -> Endpoint? {
            var c = conn.trimmingCharacters(in: .whitespaces), p = pin?.trimmingCharacters(in: .whitespaces) ?? ""
            if p.isEmpty, let colon = c.firstIndex(where: { $0 == ":" || $0 == "-" || $0 == "." }) {
                p = String(c[c.index(after: colon)...])
                c = String(c[..<colon])
            }
            guard !c.isEmpty else { return nil }
            if c.uppercased().hasPrefix("SP") {
                if splice(c) == nil { splices.append(Splice(id: c)) }
                return .splice(c)
            }
            guard !p.isEmpty else { return nil }
            if let i = connectors.firstIndex(where: { $0.id == c }) {
                if !connectors[i].cavities.contains(where: { $0.label == p }) {
                    if let n = Int(p), n > connectors[i].cavities.count, connectors[i].cavities.allSatisfy({ Int($0.label) != nil }) {
                        connectors[i].cavities += (connectors[i].cavities.count + 1...n).map { Cavity(label: String($0)) }
                    } else {
                        connectors[i].cavities.append(Cavity(label: p))
                    }
                }
            } else {
                var con = Connector(id: c, name: "", cavityCount: Int(p) ?? 1)
                if Int(p) == nil { con.cavities = [Cavity(label: p)] }
                connectors.append(con)
                report.connectorsCreated.append(c)
            }
            return .pin(connector: c, cavity: p)
        }

        for (n, r) in rows.dropFirst().enumerated() {
            func v(_ i: Int?) -> String? {
                guard let i, i < r.count else { return nil }
                let s = r[i].trimmingCharacters(in: .whitespaces)
                return s.isEmpty ? nil : s
            }
            guard let fromC = v(iFrom), let toC = v(iTo),
                  let a = endpoint(fromC, v(iFromPin)), let b = endpoint(toC, v(iToPin)) else {
                report.skippedRows.append("Row \(n + 2): missing From/To")
                continue
            }
            let size: WireSize = {
                guard let s = v(iSize)?.lowercased() else { return .awg(20) }
                let number = Double(s.drop { !$0.isNumber && $0 != "." }.prefix { $0.isNumber || $0 == "." }) ?? 0
                if s.contains("mm") || (number > 0 && number < 4 && s.contains(".")) { return WireSize(mm2: number) }
                return number > 0 ? .awg(Int(number)) : .awg(20)
            }()
            let color: WireColor = {
                guard let c = v(iColor)?.uppercased() else { return WireColor("BK") }
                let parts = c.split(whereSeparator: { "/-_ ".contains($0) }).map(String.init)
                return WireColor(parts.first ?? "BK", stripe: parts.count > 1 ? parts[1] : nil)
            }()
            var id = v(iWire) ?? nextID(prefix: "W")
            if wire(id) != nil { id = nextID(prefix: "W") }
            var w = Wire(id: id, signal: v(iSignal), size: size, color: color, insulation: v(iIns) ?? "TXL",
                         from: a, to: b, lengthOverrideMM: v(iLen).flatMap(Double.init), markerText: v(iMarker))
            if let cab = v(iCable) {
                if cable(cab) == nil { cables.append(Cable(id: cab)) }
                w.cableID = cab
            }
            wires.append(w)
            report.wiresAdded += 1
        }
        return report
    }

    /// Imports a device pin list (ICD spreadsheet) into a connector: Pin/Cavity and Signal columns.
    mutating func importPinList(csv text: String, into connectorID: EntityID) -> Int {
        let rows = CSV.parse(text)
        guard let header = rows.first, let ci = connectors.firstIndex(where: { $0.id == connectorID }) else { return 0 }
        let cols = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let iPin = cols.firstIndex(where: { ["pin", "cavity", "pin #", "position"].contains($0) }) else { return 0 }
        let iSig = cols.firstIndex { ["signal", "name", "function", "net"].contains($0) }
        var count = 0
        for r in rows.dropFirst() where iPin < r.count {
            let pin = r[iPin].trimmingCharacters(in: .whitespaces)
            guard !pin.isEmpty else { continue }
            let sig = iSig.flatMap { $0 < r.count ? r[$0].trimmingCharacters(in: .whitespaces) : nil }
            if let j = connectors[ci].cavities.firstIndex(where: { $0.label == pin }) {
                connectors[ci].cavities[j].signal = sig
            } else {
                connectors[ci].cavities.append(Cavity(label: pin, signal: sig))
            }
            count += 1
        }
        return count
    }
}
