import Foundation

/// Text-driven harness editing, shared by the `crimp` CLI, the in-app assistant and Shortcuts actions,
/// so "C1:2", "18awg", "red/white" and "6in" mean the same everywhere and edits are checked the same way.
public enum HarnessScript {
    // MARK: Parsing

    /// "152.4mm", "6in", "6\"", "0.5ft", "15cm", "1m"; a plain number is millimetres.
    public static func length(_ s: String) throws -> Double {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, Double)] = [("mm", 1), ("cm", 10), ("in", 25.4), ("\"", 25.4), ("ft", 304.8), ("m", 1000)]
        for (suffix, factor) in units where t.hasSuffix(suffix) {
            // Rounded to 0.001 mm so 6in is stored as 152.4, not 152.39999999999998.
            if let v = Double(t.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) { return (v * factor * 1000).rounded() / 1000 }
        }
        if let v = Double(t) { return v }
        throw EditError.invalid("Can't read the length \(s); use e.g. 152.4mm or 6in")
    }

    /// "18awg", "18 AWG", "18", "0.5mm2", "0.5 mm²".
    public static func wireSize(_ s: String) throws -> WireSize {
        let t = s.lowercased().replacingOccurrences(of: " ", with: "")
        if t.hasSuffix("awg"), let n = Int(t.dropLast(3)) { return .awg(n) }
        for suffix in ["mm2", "mm²", "sqmm"] where t.hasSuffix(suffix) {
            if let v = Double(t.dropLast(suffix.count)) { return WireSize(mm2: v) }
        }
        if let n = Int(t) { return .awg(n) }
        throw EditError.invalid("Can't read the wire size \(s); use e.g. 18awg or 0.5mm2")
    }

    public static let colorNames: [String: String] = [
        "black": "BK", "brown": "BN", "red": "RD", "orange": "OG", "yellow": "YE", "yel": "YE", "green": "GN", "gn": "GN",
        "blue": "BU", "violet": "VT", "purple": "VT", "grey": "GY", "gray": "GY", "white": "WH", "pink": "PK", "turquoise": "TQ",
        "light blue": "LB", "lt blue": "LB", "ltblue": "LB", "light green": "LG", "lt green": "LG", "ltgreen": "LG",
        "dark blue": "DB", "dk blue": "DB", "dark green": "DG", "dk green": "DG", "tan": "TN", "beige": "BG",
        "gold": "GD", "silver": "SR",
    ]

    /// A colour name ("red") or IEC 60757 code ("RD").
    public static func colorCode(_ s: String) throws -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let c = colorNames[trimmed.lowercased()] { return c }
        let upper = trimmed.uppercased()
        if WireTables.iecColors[upper] != nil { return upper }
        throw EditError.invalid("Unknown wire colour \(s); use a name (red) or an IEC code (RD)")
    }

    /// "red", "RD", "red/white", "RD/WH" or "VT GY" (base and stripe).
    public static func wireColor(_ s: String) throws -> WireColor {
        var parts = s.split(separator: "/").map(String.init)
        if parts.count == 1, (try? colorCode(s)) == nil {
            let words = s.split(separator: " ").map(String.init)
            if words.count == 2, (try? colorCode(words[0])) != nil, (try? colorCode(words[1])) != nil { parts = words }
        }
        guard let base = parts.first else { throw EditError.invalid("Give a wire colour, e.g. red or RD/WH") }
        return WireColor(try colorCode(base), stripe: parts.count > 1 ? try colorCode(parts[1]) : nil)
    }

    /// "C1:2" (a cavity), "SP1" (a splice), or "T1" (a one-cavity terminal).
    public static func endpoint(_ s: String, in h: Harness) throws -> Endpoint {
        let text = s.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            guard let c = h.connector(parts[0]) else { throw EditError.notFound(parts[0]) }
            guard c.cavities.contains(where: { $0.label == parts[1] }) else {
                throw EditError.invalid("\(parts[0]) has no cavity \(parts[1]); it has \(c.cavities.map(\.label).joined(separator: ", "))")
            }
            return .pin(connector: parts[0], cavity: parts[1])
        }
        if h.splice(text) != nil { return .splice(text) }
        if let c = h.connector(text), c.cavities.count == 1 { return .pin(connector: text, cavity: c.cavities[0].label) }
        throw EditError.invalid("Can't find the wire end \(s); use C1:2 for a cavity or SP1 for a splice")
    }

    /// Where a new item goes when no position is given: to the right of everything drawn so far.
    public static func defaultPoint(in h: Harness) -> Point2D {
        let maxX = h.nodes.map(\.position.x).max() ?? 0
        return Point2D(h.nodes.isEmpty ? 120 : maxX + 160, 240)
    }

    // MARK: Connectors

    /// What to place; anything left nil comes from the parts library or the defaults.
    public struct ConnectorSpec: Sendable {
        public var mpn: String
        public var manufacturer: String?
        public var description: String?
        public var cavities: Int?
        public var kind: ConnectorKind = .housing
        public var id: EntityID?
        public var name: String?
        public var gender: Gender?
        public var sealed = false

        public init(mpn: String, manufacturer: String? = nil, description: String? = nil, cavities: Int? = nil) {
            self.mpn = mpn
            self.manufacturer = manufacturer
            self.description = description
            self.cavities = cavities
        }
    }

    /// The part to place and the library entry (photo, terminals, seals…) that comes with it.
    public static func part(for spec: ConnectorSpec, library: PartLibrary?) -> (PartRef, LibraryPart?) {
        var part = spec.mpn.uppercased() == "GENERIC"
            ? PartRef.generic(spec.description ?? "Generic connector")
            : PartRef(mpn: spec.mpn, manufacturer: spec.manufacturer ?? "", description: spec.description)
        let config = library?.entry(for: part)
        if let config {
            // Take the library's copy, keeping anything given explicitly.
            let given = part
            part = config.part
            part.description = given.description ?? part.description
            if !given.manufacturer.isEmpty { part.manufacturer = given.manufacturer }
        }
        return (part, config)
    }

    /// Places a connector and applies its library configuration. Returns its designator.
    @discardableResult
    public static func addConnector(_ spec: ConnectorSpec, part: PartRef, config: LibraryPart?, to h: inout Harness,
                                    at point: Point2D? = nil) throws -> EntityID {
        var part = part, config = config
        if let n = spec.cavities {
            guard n > 0, n <= 300 else { throw EditError.invalid("A connector needs 1–300 cavities") }
            part.positionCount = n
            if config?.cavityCount != nil { config?.cavityCount = n }
        }
        if !spec.kind.isLooseTerminal, part.positionCount == nil, config?.cavityCount == nil {
            throw EditError.invalid("How many cavities does \(spec.mpn) have? Give the cavity count.")
        }
        if let wanted = spec.id, h.connector(wanted) != nil || h.splice(wanted) != nil {
            throw EditError.invalid("\(wanted) is already used")
        }
        var id = h.placeConnector(part: part, kind: spec.kind, at: point ?? defaultPoint(in: h), configuration: config)
        if let wanted = spec.id, wanted != id, h.renameConnector(id, to: wanted) { id = wanted }
        if let i = h.connectors.firstIndex(where: { $0.id == id }) {
            if let n = spec.name { h.connectors[i].name = n }
            if let g = spec.gender { h.connectors[i].gender = g }
            if spec.sealed { h.connectors[i].sealed = true }
        }
        return id
    }

    // MARK: Wires

    /// Adds a wire between two ends written as text. Refuses a second wire in a cavity unless it is a double crimp.
    @discardableResult
    public static func addWire(from: String, to: String, size: String? = nil, color: String? = nil, signal: String? = nil,
                               insulation: String? = nil, doubleCrimp: Bool = false, addBundle: Bool = true,
                               id: EntityID? = nil, in h: inout Harness) throws -> EntityID {
        let a = try endpoint(from, in: h), b = try endpoint(to, in: h)
        guard a != b else { throw EditError.invalid("Both ends are the same") }
        for e in [a, b] where !doubleCrimp && e.connectorID != nil && h.isOccupied(e) {
            throw EditError.invalid("\(e) already has a wire; mark it a double crimp if two wires share that terminal")
        }
        if let id, h.wire(id) != nil { throw EditError.invalid("\(id) is already used") }
        var wid = h.connect(a, b, size: try size.map(wireSize) ?? .awg(20), color: try color.map(wireColor) ?? WireColor("BK"),
                            signal: signal, insulation: insulation ?? "TXL", addBundleIfMissing: addBundle, doubleCrimp: doubleCrimp)
        if let id, let i = h.wires.firstIndex(where: { $0.id == wid }) {
            h.wires[i].id = id
            wid = id
        }
        return wid
    }

    // MARK: Summary

    /// A compact, plain-text description of a harness, small enough for an on-device model's context.
    public static func summary(of h: Harness, analysis: HarnessAnalysis? = nil, maxWires: Int = 60) -> String {
        let a = analysis ?? HarnessAnalysis(h)
        let u = h.settings.units
        var lines = ["Harness \"\(h.name)\" rev \(h.revision), units \(u.rawValue)."]
        if h.connectors.isEmpty { lines.append("No connectors yet.") }
        for c in h.connectors {
            let used = c.cavities.filter { h.isOccupied(.pin(connector: c.id, cavity: $0.label)) }.map(\.label)
            let free = c.cavities.map(\.label).filter { !used.contains($0) }
            let part = c.part.map { $0.isGeneric ? ($0.description ?? "generic") : "\($0.manufacturer) \($0.mpn)" } ?? "no part"
            lines.append("\(c.id)\(c.name.isEmpty ? "" : " \"\(c.name)\""): \(part), \(c.cavities.count) cavities, used [\(used.joined(separator: ","))], free [\(free.joined(separator: ","))]")
        }
        if !h.splices.isEmpty { lines.append("Splices: " + h.splices.map(\.id).joined(separator: ", ")) }
        if !h.segments.isEmpty {
            func name(_ n: EntityID) -> String {
                h.connectors.first { $0.nodeID == n }?.id ?? h.splices.filter { $0.nodeID == n }.map(\.id).joined(separator: "/").nonEmpty ?? n
            }
            lines.append("Bundles: " + h.segments.map { "\($0.id) \(name($0.nodeA))–\(name($0.nodeB)) \(u.format($0.lengthMM))" }.joined(separator: "; "))
        }
        for w in h.wires.prefix(maxWires) {
            let len = a.routes[w.id]?.lengthMM.map { u.format($0) } ?? "no route"
            lines.append("\(w.id): \(w.from) → \(w.to), \(w.size) \(w.color)\(w.signal.map { ", \($0)" } ?? ""), \(len)")
        }
        if h.wires.count > maxWires { lines.append("…and \(h.wires.count - maxWires) more wires.") }
        let errors = a.issues.filter { $0.severity == .error }, warnings = a.issues.filter { $0.severity == .warning }
        lines.append("Rule check: \(errors.count) errors, \(warnings.count) warnings.")
        return lines.joined(separator: "\n")
    }

    /// Open rule-check results as text, errors first.
    public static func issues(of h: Harness, analysis: HarnessAnalysis? = nil) -> String {
        let a = analysis ?? HarnessAnalysis(h)
        let open = a.issues.filter { $0.severity != .info }
        guard !open.isEmpty else { return "No errors or warnings." }
        return open.map { "\($0.severity.rawValue) \($0.subject): \($0.message)" }.joined(separator: "\n")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
