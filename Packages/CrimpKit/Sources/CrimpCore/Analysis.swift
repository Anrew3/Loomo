import Foundation

public struct WireRoute: Hashable, Sendable {
    public var segmentIDs: [EntityID] = []
    /// Length along the topology. Nil when no path was found.
    public var pathLengthMM: Double?
    /// Termination allowance + insertion depth + backshell entry at each end.
    public var endAllowanceAMM: Double = 0
    public var endAllowanceBMM: Double = 0
    /// Extra length a twisted wire needs over the bundle length.
    public var twistTakeUpMM: Double = 0
    public var extraMM: Double = 0
    /// Final manufacturing length: the override, or the sum of the parts above.
    public var lengthMM: Double?
    public var isOverridden = false
}

public struct Issue: Identifiable, Hashable, Sendable {
    public enum Severity: String, Sendable { case error, warning, info }
    public var id: String { "\(severity.rawValue):\(subject):\(message)" }
    public var severity: Severity
    /// The item to jump to: a connector, wire, splice, covering, cable, label… or "C1:3".
    public var subject: EntityID
    public var message: String
    /// Set when the engineer accepted this check; the issue is then reported as info.
    public var acceptedReason: String? = nil
}

public struct BOMLine: Identifiable, Hashable, Sendable {
    public enum Unit: String, Sendable { case each = "ea", mm = "mm" }
    public var id: String { "\(category)|\(partKey)" }
    public var category: String
    public var partKey: String
    public var mpn: String
    public var manufacturer: String
    public var internalPN: String
    public var description: String
    public var quantity: Double
    public var unit: Unit
    public var references: [EntityID]
    public var unitPrice: Double?
    public var alternates: [String]
    /// Quantity the design produced before a manual override.
    public var computedQuantity: Double = 0
    public var isOverridden = false
    /// Item number on the drawing and BOM, counted in BOM order from 1.
    public var item: Int = 0

    /// Price for `.each` lines; `.mm` lines are priced per metre.
    public var extendedPrice: Double? {
        guard let unitPrice else { return nil }
        return unit == .each ? unitPrice * quantity : unitPrice * quantity / 1000
    }
}

public struct CutListRow: Identifiable, Hashable, Sendable {
    public var id: EntityID { wireID }
    public var wireID: EntityID
    /// "Wire", "Drain", or "Cable jacket".
    public var kind: String
    public var cable: String
    public var twist: String
    public var signal: String
    public var size: String
    public var color: String
    public var insulation: String
    public var cutLengthMM: Double?
    public var endA: String
    public var terminalA: String
    public var sealA: String
    public var stripA: Double?
    public var endB: String
    public var terminalB: String
    public var sealB: String
    public var stripB: Double?
    public var marker: String
}

public struct ConnectionRow: Identifiable, Hashable, Sendable {
    public var id: String { cavity + "|" + wireID }
    public var cavity: String
    public var signal: String
    public var wireID: String
    public var size: String
    public var color: String
    public var destination: String
    public var terminal: String
    public var seal: String
    /// Wires this one is twisted with ("W4"), or empty.
    public var twistedWith: String = ""
    /// Conductor name and colour as drawings print it: "CANHIN.YE", or just the colour without a name.
    public var conductor: String = ""
}

public struct ConnectorTable: Identifiable, Hashable, Sendable {
    public var id: EntityID { connectorID }
    public var connectorID: EntityID
    public var title: String
    public var rows: [ConnectionRow]
}

public struct Net: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var members: [String]
    public var wires: [EntityID]
}

public struct LabelRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var location: String
    public var part: String
}

public struct ToolRow: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: String
    public var partNumber: String
    public var usedFor: [String]
}

/// Derived engineering data for a harness. Cheap to recompute after each edit.
public struct HarnessAnalysis: Sendable {
    public let routes: [EntityID: WireRoute]
    /// Wires that pass through each segment.
    public let segmentWires: [EntityID: [EntityID]]
    public let bundleDiameterMM: [EntityID: Double]
    public let bom: [BOMLine]
    public let cutList: [CutListRow]
    public let connectorTables: [ConnectorTable]
    /// Wires joined at each splice, laid out like connector tables (the "cavity" column is the wire end).
    public let spliceTables: [ConnectorTable]
    /// BOM item number for each designator (C1, W3, CV1, SP1, …) — the item it is mainly bought as.
    public let itemNumbers: [EntityID: Int]
    public let nets: [Net]
    public let labelList: [LabelRow]
    public let toolList: [ToolRow]
    public let issues: [Issue]

    public init(_ h: Harness) {
        let signpost = Signposts.signposter.beginInterval("Analyse harness", id: Signposts.signposter.makeSignpostID())
        defer { Signposts.signposter.endInterval("Analyse harness", signpost) }
        var issues: [Issue] = []
        let graph = TopologyGraph(h)
        let twistOf = Dictionary(h.twists.flatMap { t in t.wireIDs.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })

        // Routing and lengths
        let lookup = HarnessLookup(h)
        var routes: [EntityID: WireRoute] = [:]
        var segmentWires: [EntityID: [EntityID]] = [:]
        for wire in h.wires {
            var route = WireRoute()
            let a = Self.node(for: wire.from, in: h, lookup: lookup), b = Self.node(for: wire.to, in: h, lookup: lookup)
            if let a, let b, let path = graph.shortestPath(from: a, to: b) {
                route.segmentIDs = path.segments
                route.pathLengthMM = path.length
                route.endAllowanceAMM = Self.endAllowance(wire.from, h, lookup)
                route.endAllowanceBMM = Self.endAllowance(wire.to, h, lookup)
                if let t = twistOf[wire.id], t.layLengthMM > 0 {
                    let factor = (1 + pow(.pi * wire.outerDiameterMM / t.layLengthMM, 2)).squareRoot()
                    route.twistTakeUpMM = path.length * (factor - 1)
                }
                route.extraMM = wire.extraLengthMM
                route.lengthMM = path.length + route.endAllowanceAMM + route.endAllowanceBMM + route.twistTakeUpMM + route.extraMM
                for s in path.segments { segmentWires[s, default: []].append(wire.id) }
            } else if let side = [(wire.from, "A"), (wire.to, "B")].first(where: { $0.0 == .unassigned })?.1 {
                issues.append(Issue(severity: .warning, subject: wire.id,
                                    message: "End \(side) is not assigned to a cavity or splice."))
            } else if wire.lengthOverrideMM == nil {
                issues.append(Issue(severity: .error, subject: wire.id,
                                    message: "No route between \(wire.from) and \(wire.to); place both ends on connected nodes or set a length override."))
            }
            if let override = wire.lengthOverrideMM {
                route.lengthMM = override
                route.isOverridden = true
            }
            routes[wire.id] = route
        }

        // Bundle diameters: loose wires count individually, cables count once by jacket.
        let wiresByID = Dictionary(uniqueKeysWithValues: h.wires.map { ($0.id, $0) })
        var bundle: [EntityID: Double] = [:]
        for seg in h.segments {
            var ods: [Double] = []
            var cablesSeen: Set<EntityID> = []
            for wid in segmentWires[seg.id] ?? [] {
                guard let w = wiresByID[wid] else { continue }
                if let cid = w.cableID, let cable = h.cable(cid) {
                    if cablesSeen.insert(cid).inserted { ods.append(cable.jacketODMM) }
                } else {
                    ods.append(w.outerDiameterMM)
                }
            }
            let sumSq = ods.reduce(0) { $0 + $1 * $1 }
            bundle[seg.id] = ods.count == 1 ? ods[0] : h.settings.bundlePackingFactor * sumSq.squareRoot()
        }

        issues += Self.check(h, routes: routes, bundle: bundle, lookup: lookup)
        self.routes = routes
        self.segmentWires = segmentWires
        self.bundleDiameterMM = bundle
        let bom = Self.buildBOM(h, routes: routes, bundle: bundle)
        self.bom = bom
        var items: [EntityID: Int] = [:]
        for line in bom { for r in line.references where items[r] == nil { items[r] = line.item } }
        self.itemNumbers = items
        self.cutList = Self.buildCutList(h, routes: routes, twistOf: twistOf, lookup: lookup)
        self.connectorTables = Self.buildConnectorTables(h, twistOf: twistOf)
        self.spliceTables = Self.buildSpliceTables(h, twistOf: twistOf)
        self.nets = Self.buildNets(h)
        self.labelList = Self.buildLabels(h)
        self.toolList = Self.buildTools(h)
        // Reviewed deviations: an accepted error or warning is kept, but as info with its reason.
        for i in issues.indices where issues[i].severity != .info {
            if let a = h.acceptedIssues.first(where: { $0.subject == issues[i].subject && $0.message == issues[i].message }) {
                issues[i].severity = .info
                issues[i].acceptedReason = a.reason
            }
        }
        self.issues = issues.sorted { ($0.severity.rank, $0.subject) < ($1.severity.rank, $1.subject) }
    }

    public static func node(for endpoint: Endpoint, in h: Harness) -> EntityID? {
        node(for: endpoint, in: h, lookup: nil)
    }

    static func node(for endpoint: Endpoint, in h: Harness, lookup: HarnessLookup?) -> EntityID? {
        switch endpoint {
        case let .pin(c, _): return (lookup.map { $0.connector(c) } ?? h.connector(c))?.nodeID
        case let .splice(s): return (lookup.map { $0.splice(s) } ?? h.splice(s))?.nodeID
        case .unassigned: return nil
        }
    }

    static func endAllowance(_ e: Endpoint, _ h: Harness, _ lookup: HarnessLookup? = nil) -> Double {
        switch e {
        case let .pin(c, _):
            let con = lookup.map { $0.connector(c) } ?? h.connector(c)
            // A pigtail's own lead covers that much of the route: the harness wire is spliced to it there.
            let lead = con?.kind == .pigtail ? (con?.leadLengthMM ?? 0) : 0
            return h.settings.terminationAllowanceMM + (con?.insertionDepthMM ?? 0) + (con?.backshellEntryMM ?? 0) - lead
        case .splice: return h.settings.terminationAllowanceMM
        case .unassigned: return 0
        }
    }

    static func stripLength(_ e: Endpoint, _ h: Harness, _ lookup: HarnessLookup? = nil) -> Double? {
        switch e {
        case .pin: return (lookup.map { $0.cavity(e) } ?? h.cavity(e))?.terminal?.stripLengthMM
        case let .splice(s): return (lookup.map { $0.splice(s) } ?? h.splice(s))?.part?.stripLengthMM
        case .unassigned: return nil
        }
    }

    // MARK: Covering quantities

    /// Material needed for a covering, in millimetres of tube/sleeve/tape.
    public static func coveringQuantityMM(_ c: Covering, in h: Harness, bundle: [EntityID: Double]) -> Double {
        let margin = 1 + h.settings.materialMarginPercent / 100
        var total = 0.0
        for sid in c.segmentIDs {
            guard let seg = h.segment(sid) else { continue }
            let length = seg.lengthMM
            guard c.kind == .tape, let tape = c.tape else {
                total += length
                continue
            }
            let circumference = Double.pi * max(bundle[sid] ?? 0, 1)
            switch tape.style {
            case .halfLap:
                let pitch = tape.widthMM * 0.5
                total += (length / pitch) * hypot(circumference, pitch)
            case .spiral:
                let pitch = max(tape.pitchMM, tape.widthMM)
                total += (length / pitch) * hypot(circumference, pitch)
            case .spot:
                let spots = (length / max(tape.pitchMM, 1)).rounded(.up) + 1
                total += spots * Double(tape.turnsPerSpot) * circumference
            }
        }
        return total * margin
    }

    // MARK: Rules

    static func check(_ h: Harness, routes: [EntityID: WireRoute], bundle: [EntityID: Double], lookup L: HarnessLookup) -> [Issue] {
        var issues: [Issue] = []
        func add(_ s: Issue.Severity, _ subject: EntityID, _ m: String) { issues.append(Issue(severity: s, subject: subject, message: m)) }
        var used: [String: [EntityID]] = [:]

        for w in h.wires {
            for end in [w.from, w.to] {
                switch end {
                case let .pin(cid, cav):
                    guard let c = L.connector(cid) else { add(.error, w.id, "Unknown connector \(cid)."); continue }
                    guard let cavity = c.cavities.first(where: { $0.label == cav }) else {
                        add(.error, w.id, "\(cid) has no cavity \(cav).")
                        continue
                    }
                    let ref = "\(cid):\(cav)"
                    used[ref, default: []].append(w.id)
                    if let t = cavity.terminal {
                        if let lo = t.minWireMM2, w.size.crossSectionMM2 < lo - 1e-6 {
                            add(.error, ref, "\(w.id) (\(w.size)) is below terminal \(t.mpn)'s \(fmt(lo)) mm² minimum.")
                        }
                        if let hi = t.maxWireMM2, w.size.crossSectionMM2 > hi + 1e-6 {
                            add(.error, ref, "\(w.id) (\(w.size)) is above terminal \(t.mpn)'s \(fmt(hi)) mm² maximum.")
                        }
                    } else if c.kind != .device {
                        add(.warning, cid, "Cavity \(cav) carries \(w.id) but has no terminal.")
                    }
                    if c.sealed {
                        if let s = cavity.seal {
                            if let lo = s.minInsulationODMM, w.outerDiameterMM < lo {
                                add(.error, ref, "\(w.id) insulation Ø\(fmt(w.outerDiameterMM)) is too small for seal \(s.mpn) (min Ø\(fmt(lo))).")
                            }
                            if let hi = s.maxInsulationODMM, w.outerDiameterMM > hi {
                                add(.error, ref, "\(w.id) insulation Ø\(fmt(w.outerDiameterMM)) is too large for seal \(s.mpn) (max Ø\(fmt(hi))).")
                            }
                        } else {
                            add(.warning, cid, "Sealed connector: cavity \(cav) needs a wire seal.")
                        }
                    }
                case let .splice(sid):
                    if L.splice(sid) == nil { add(.error, w.id, "Unknown splice \(sid).") }
                case .unassigned:
                    continue
                }
            }
        }
        for (pin, wireIDs) in used where wireIDs.count > 1 {
            let parts = pin.split(separator: ":").map(String.init)
            let cavity = parts.count == 2 ? L.cavity(.pin(connector: parts[0], cavity: parts[1])) : nil
            if cavity?.doubleCrimp == true {
                if wireIDs.count > 2 {
                    add(.error, pin, "\(wireIDs.count) wires in one terminal (\(wireIDs.joined(separator: ", "))); a double crimp takes two.")
                }
                let total = wireIDs.compactMap { L.wire($0)?.size.crossSectionMM2 }.reduce(0, +)
                if let t = cavity?.terminal, let hi = t.maxWireMM2, total > hi + 1e-6 {
                    add(.error, pin, "Double crimp totals \(fmt(total)) mm², above terminal \(t.mpn)'s \(fmt(hi)) mm² rating.")
                }
            } else {
                add(.warning, pin, "\(wireIDs.count) wires share one cavity (\(wireIDs.joined(separator: ", "))). Mark the cavity as a double crimp if the terminal takes two wires.")
            }
        }

        var seenIDs: [EntityID: Int] = [:]
        for c in h.connectors { seenIDs[c.id, default: 0] += 1 }
        for (id, n) in seenIDs where n > 1 { add(.error, id, "Reference designator \(id) is used by \(n) connectors.") }

        for c in h.connectors {
            if c.nodeID == nil { add(.warning, c.id, "Not placed on the topology.") }
            if c.part == nil && c.kind.hasHousing { add(.info, c.id, "No housing part assigned.") }
            let labels = Set(c.cavities.map(\.label))
            for item in c.boxItems {
                for cav in item.cavities where !labels.contains(cav) {
                    add(.error, c.id, "\(item.id) uses cavity \(cav), which \(c.id) doesn't have.")
                }
                if item.kind == .fuse, (item.rating ?? "").isEmpty, item.part == nil {
                    add(.warning, c.id, "Fuse \(item.id) has no rating or part.")
                }
            }
            if let m = c.mate {
                if let other = L.connector(m) {
                    if other.mate != nil, other.mate != c.id { add(.error, c.id, "\(c.id) mates with \(m), but \(m) mates with \(other.mate!).") }
                    if other.gender == c.gender { add(.warning, c.id, "\(c.id) and its mate \(m) are both \(c.gender.rawValue).") }
                    let missing = c.cavities.map(\.label).filter { l in !other.cavities.contains { $0.label == l } }
                    if !missing.isEmpty { add(.warning, c.id, "Cavities \(missing.joined(separator: ", ")) have no partner in \(m).") }
                } else {
                    add(.error, c.id, "Mates with \(m), which isn't in this harness.")
                }
            }
            if c.sealed {
                for cav in c.cavities where used["\(c.id):\(cav.label)"] == nil && cav.plug == nil {
                    add(.warning, c.id, "Unused cavity \(cav.label) on a sealed connector needs a cavity plug.")
                }
            }
            if c.kind.isLooseTerminal && c.cavities.count != 1 {
                add(.warning, c.id, "\(c.kind.title) should have exactly one cavity.")
            }
        }
        for s in h.splices {
            let joined = h.wires.filter { $0.from == .splice(s.id) || $0.to == .splice(s.id) }
            if joined.count < 2 { add(.warning, s.id, "Splice joins \(joined.count) wire(s); a splice needs at least 2.") }
            if s.nodeID == nil { add(.warning, s.id, "Splice is not placed on the topology.") }
            if let hi = s.part?.maxWireMM2 {
                let total = joined.map(\.size.crossSectionMM2).reduce(0, +)
                if total > hi + 1e-6 { add(.error, s.id, "Total \(fmt(total)) mm² exceeds splice \(s.part!.mpn)'s \(fmt(hi)) mm² rating.") }
            }
        }
        for cov in h.coverings {
            for sid in cov.segmentIDs {
                guard let d = bundle[sid] else {
                    if L.segment(sid) == nil { add(.error, cov.id, "Applied to missing segment \(sid).") }
                    continue
                }
                if let id = cov.innerDiameterMM, cov.kind != .tape, d > id {
                    add(.error, cov.id, String(format: "Bundle on %@ is Ø%.1f mm, more than the covering's Ø%.1f mm inner diameter.", sid, d, id))
                }
                if let lo = cov.minDiameterMM, d < lo {
                    add(.warning, cov.id, String(format: "Bundle on %@ is Ø%.1f mm, below the covering's Ø%.1f mm minimum; it will be loose.", sid, d, lo))
                }
            }
        }
        for t in h.twists {
            let paths = Set(t.wireIDs.compactMap { routes[$0]?.segmentIDs })
            if paths.count > 1 { add(.warning, t.id, "Twisted wires \(t.wireIDs.joined(separator: ", ")) take different routes.") }
            if t.wireIDs.count < 2 { add(.warning, t.id, "A twist needs at least two wires.") }
        }
        for cable in h.cables {
            let cores = h.wires.filter { $0.cableID == cable.id }
            if cores.isEmpty { add(.warning, cable.id, "Cable has no cores.") }
            if Set(cores.compactMap { routes[$0.id]?.segmentIDs }).count > 1 {
                add(.warning, cable.id, "Cable cores take different routes; the jacket can only follow one.")
            }
            if cable.shielded && !cores.contains(where: { $0.role != .conductor }) {
                add(.info, cable.id, "Shielded cable has no drain or shield wire to terminate.")
            }
        }
        for l in h.labels {
            switch l.placement {
            case let .segment(sid, offset):
                if let s = L.segment(sid) {
                    if offset < 0 || offset > s.lengthMM { add(.warning, l.id, "Label offset is outside segment \(sid).") }
                } else { add(.error, l.id, "Label is on missing segment \(sid).") }
            case let .connector(cid):
                if L.connector(cid) == nil { add(.error, l.id, "Label is on missing connector \(cid).") }
            }
        }
        // Generic parts are fine while designing but must be replaced before release.
        for (ref, part) in allParts(h) where part.isGeneric {
            add(.info, ref, "Generic part “\(part.description ?? "part")”; replace with an exact part before release.")
        }
        return issues
    }

    /// Every part reference in the design with the item that holds it.
    public static func allParts(_ h: Harness) -> [(EntityID, PartRef)] {
        var out: [(EntityID, PartRef)] = []
        for c in h.connectors {
            if let p = c.part { out.append((c.id, p)) }
            for a in c.accessories { out.append((c.id, a.part)) }
            for cav in c.cavities {
                for p in [cav.terminal, cav.seal, cav.plug].compactMap({ $0 }) { out.append(("\(c.id):\(cav.label)", p)) }
            }
        }
        for w in h.wires { if let p = w.part { out.append((w.id, p)) } }
        for c in h.cables { if let p = c.part { out.append((c.id, p)) } }
        for s in h.splices { for p in [s.part, s.heatShrink].compactMap({ $0 }) { out.append((s.id, p)) } }
        for c in h.coverings { if let p = c.part { out.append((c.id, p)) } }
        for l in h.labels { if let p = l.part { out.append((l.id, p)) } }
        for n in h.nodes { if let p = n.part { out.append((n.id, p)) } }
        return out
    }

    // MARK: BOM

    static func buildBOM(_ h: Harness, routes: [EntityID: WireRoute], bundle: [EntityID: Double]) -> [BOMLine] {
        var lines: [String: BOMLine] = [:]

        func add(_ category: String, _ part: PartRef?, fallback: String, qty: Double, unit: BOMLine.Unit, ref: EntityID) {
            let key = part.map { $0.isGeneric ? "generic|\($0.description ?? fallback)" : "\($0.manufacturer)|\($0.mpn)" } ?? "unassigned|\(fallback)"
            let id = "\(category)|\(key)"
            if lines[id] == nil {
                lines[id] = BOMLine(category: category, partKey: key, mpn: part?.mpn ?? "—",
                                    manufacturer: part?.manufacturer ?? "—", internalPN: part?.internalPN ?? "",
                                    description: part?.description ?? fallback,
                                    quantity: 0, unit: unit, references: [], unitPrice: part?.unitPrice,
                                    alternates: part?.alternates ?? [])
            }
            lines[id]!.quantity += qty
            if !lines[id]!.references.contains(ref) { lines[id]!.references.append(ref) }
        }

        let usedCavities = Set(h.wires.flatMap { [$0.from, $0.to] }.compactMap { end -> String? in
            if case let .pin(c, cav) = end { return "\(c):\(cav)" }
            return nil
        })

        for c in h.connectors where c.kind != .device {
            if c.kind.hasHousing {
                let category = switch c.kind {
                case .fuseBox: "Fuse box"
                case .relay: "Relay socket"
                default: "Connector"
                }
                let fallback = switch c.kind {
                case .fuseBox: "\(c.cavities.count)-way fuse holder"
                case .relay: "relay socket"
                case .pigtail: "\(c.cavities.count)-way pigtail"
                default: "\(c.cavities.count)-way housing"
                }
                add(category, c.part, fallback: fallback, qty: 1, unit: .each, ref: c.id)
            }
            for item in c.boxItems where item.kind != .jumper || item.part != nil {
                let fallback = [item.rating, item.kind.title.lowercased()].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                add(item.kind.title, item.part, fallback: fallback, qty: 1, unit: .each, ref: "\(c.id)/\(item.id)")
            }
            for a in c.accessories {
                add(AccessoryKinds.category(a.kind), a.part, fallback: a.kind, qty: Double(a.quantity), unit: .each, ref: c.id)
            }
            for cav in c.cavities {
                let ref = "\(c.id):\(cav.label)"
                if usedCavities.contains(ref) {
                    let terminal = cav.terminal ?? (c.kind.isLooseTerminal ? c.part : nil)
                    if let t = terminal { add("Terminal", t, fallback: "terminal", qty: 1, unit: .each, ref: ref) }
                    if let s = cav.seal { add("Seal", s, fallback: "wire seal", qty: 1, unit: .each, ref: ref) }
                } else if let p = cav.plug {
                    add("Cavity plug", p, fallback: "cavity plug", qty: 1, unit: .each, ref: ref)
                }
            }
        }
        for w in h.wires {
            let fallback = "\(w.insulation) \(w.size) \(w.color)"
            // Cable cores are bought as part of the cable.
            if w.cableID != nil, let cid = w.cableID, h.cable(cid)?.part != nil { continue }
            add("Wire", w.part, fallback: fallback, qty: routes[w.id]?.lengthMM ?? 0, unit: .mm, ref: w.id)
        }
        for c in h.cables {
            add("Cable", c.part, fallback: c.name.isEmpty ? "cable" : c.name, qty: cableJacketLength(c, h, routes) ?? 0, unit: .mm, ref: c.id)
        }
        for s in h.splices {
            add("Splice", s.part, fallback: s.kind.title + (s.value.map { " \($0)" } ?? ""), qty: 1, unit: .each, ref: s.id)
            if let hs = s.heatShrink { add("Heat shrink", hs, fallback: "splice heat shrink", qty: 1, unit: .each, ref: s.id) }
        }
        for cov in h.coverings {
            let qty = coveringQuantityMM(cov, in: h, bundle: bundle)
            let category = switch cov.kind {
            case .tape: "Tape"
            case .heatShrink: "Heat shrink"
            default: "Sleeving"
            }
            add(category, cov.part, fallback: cov.kind.rawValue, qty: qty.rounded(.up), unit: .mm, ref: cov.id)
        }
        for n in h.nodes where n.part != nil {
            add("Clip", n.part, fallback: "clip", qty: 1, unit: .each, ref: n.id)
        }
        for l in h.labels {
            add("Label", l.part, fallback: "bundle label", qty: 1, unit: .each, ref: l.id)
        }
        for x in h.bomExtraLines {
            add(x.category, x.part, fallback: x.part.description ?? "item", qty: x.quantity, unit: .each, ref: "manual")
        }
        for id in lines.keys {
            lines[id]!.computedQuantity = lines[id]!.quantity
            if let q = h.bomQuantityOverrides[id] {
                lines[id]!.quantity = q
                lines[id]!.isOverridden = true
            }
        }
        for id in h.bomExcluded { lines[id] = nil }

        let order = ["Connector", "Fuse box", "Relay socket", "Fuse", "Relay", "Circuit breaker", "Diode", "Jumper"]
            + AccessoryKinds.all + ["Accessory", "Terminal", "Seal", "Cavity plug", "Wire", "Cable", "Splice", "Heat shrink",
                                    "Sleeving", "Tape", "Clip", "Label", "Other"]
        let sorted = lines.values.sorted {
            let a = order.firstIndex(of: $0.category) ?? 99, b = order.firstIndex(of: $1.category) ?? 99
            return (a, $0.mpn, $0.description) < (b, $1.mpn, $1.description)
        }
        return sorted.enumerated().map { i, line in
            var line = line
            line.item = i + 1
            return line
        }
    }

    /// Jacket length: the longest core minus the jacket stripped back at each end.
    public static func cableJacketLength(_ c: Cable, _ h: Harness, _ routes: [EntityID: WireRoute]) -> Double? {
        let lengths = h.wires.filter { $0.cableID == c.id }.compactMap { routes[$0.id]?.lengthMM }
        guard let longest = lengths.max() else { return nil }
        return max(0, longest - 2 * c.jacketStripMM)
    }

    // MARK: Cut list

    static func buildCutList(_ h: Harness, routes: [EntityID: WireRoute], twistOf: [EntityID: Twist], lookup L: HarnessLookup) -> [CutListRow] {
        func detail(_ end: Endpoint) -> (String, String, String) {
            switch end {
            case let .pin(c, _):
                let con = L.connector(c)
                let cavity = L.cavity(end)
                let terminal = cavity?.terminal ?? (con?.kind.isLooseTerminal == true ? con?.part : nil)
                return (end.description, terminal?.mpn ?? "—", cavity?.seal?.mpn ?? "—")
            case let .splice(s):
                return (s, L.splice(s)?.part?.mpn ?? L.splice(s)?.kind.title ?? "splice", "—")
            case .unassigned:
                return ("—", "—", "—")
            }
        }
        let step = max(h.settings.cutLengthRoundingMM, 1)
        func round(_ v: Double?) -> Double? { v.map { ($0 / step).rounded(.up) * step } }
        var rows: [CutListRow] = h.wires.map { w in
            let a = detail(w.from), b = detail(w.to)
            return CutListRow(wireID: w.id, kind: w.role == .conductor ? "Wire" : w.role.rawValue.capitalized,
                              cable: w.cableID ?? "", twist: twistOf[w.id]?.id ?? "",
                              signal: w.signal ?? "", size: w.size.description,
                              color: w.color.description, insulation: w.insulation, cutLengthMM: round(routes[w.id]?.lengthMM),
                              endA: a.0, terminalA: a.1, sealA: a.2, stripA: stripLength(w.from, h, L),
                              endB: b.0, terminalB: b.1, sealB: b.2, stripB: stripLength(w.to, h, L),
                              marker: w.markerText ?? "")
        }
        for c in h.cables {
            rows.append(CutListRow(wireID: c.id, kind: "Cable jacket", cable: c.id, twist: "", signal: c.name,
                                   size: c.part?.mpn ?? "", color: "", insulation: c.shielded ? "Shielded" : "",
                                   cutLengthMM: round(cableJacketLength(c, h, routes)),
                                   endA: "", terminalA: "", sealA: "", stripA: c.jacketStripMM,
                                   endB: "", terminalB: "", sealB: "", stripB: c.jacketStripMM, marker: ""))
        }
        return rows
    }

    // MARK: Connection tables, nets, labels, tools

    /// "CANHIN.YE", "YE/BK" when the wire has no name.
    public static func conductorName(_ w: Wire) -> String {
        guard let s = w.signal?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return w.color.description }
        return "\(s).\(w.color.description)"
    }

    static func twistedWith(_ w: Wire, _ twistOf: [EntityID: Twist]) -> String {
        twistOf[w.id].map { $0.wireIDs.filter { $0 != w.id }.joined(separator: ", ") } ?? ""
    }

    static func buildSpliceTables(_ h: Harness, twistOf: [EntityID: Twist]) -> [ConnectorTable] {
        h.splices.map { s in
            let here = Endpoint.splice(s.id)
            let rows = h.wires.filter { $0.from == here || $0.to == here }.map { w in
                let other = w.from == here ? w.to : w.from
                return ConnectionRow(cavity: w.id, signal: w.signal ?? "", wireID: w.id, size: w.size.description,
                                     color: w.color.description, destination: other.description,
                                     terminal: s.part?.mpn ?? "", seal: "", twistedWith: twistedWith(w, twistOf),
                                     conductor: conductorName(w))
            }
            return ConnectorTable(connectorID: s.id, title: "\(s.id) · \(s.kind.title)", rows: rows)
        }
    }

    static func buildConnectorTables(_ h: Harness, twistOf: [EntityID: Twist] = [:]) -> [ConnectorTable] {
        // Wires at each end, found once rather than searching every wire for every cavity.
        var wiresAt: [Endpoint: [Wire]] = [:]
        for w in h.wires {
            wiresAt[w.from, default: []].append(w)
            if w.to != w.from { wiresAt[w.to, default: []].append(w) }
        }
        return h.connectors.map { c in
            let rows = c.cavities.flatMap { cav -> [ConnectionRow] in
                let here = Endpoint.pin(connector: c.id, cavity: cav.label)
                let wires = wiresAt[here] ?? []
                if wires.isEmpty {
                    return [ConnectionRow(cavity: cav.label, signal: cav.signal ?? "", wireID: "", size: "", color: "",
                                          destination: cav.plug.map { "plug \($0.mpn)" } ?? "",
                                          terminal: "", seal: "")]
                }
                return wires.map { w in
                    let other = w.from == here ? w.to : w.from
                    let terminal = cav.terminal ?? (c.kind.isLooseTerminal ? c.part : nil)
                    return ConnectionRow(cavity: cav.label, signal: w.signal ?? cav.signal ?? "", wireID: w.id,
                                         size: w.size.description, color: w.color.description, destination: other.description,
                                         terminal: terminal?.mpn ?? "", seal: cav.seal?.mpn ?? "",
                                         twistedWith: twistedWith(w, twistOf), conductor: conductorName(w))
                }
            }
            let title = [c.id, c.name, c.part?.mpn].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return ConnectorTable(connectorID: c.id, title: title, rows: rows)
        }
    }

    static func buildNets(_ h: Harness) -> [Net] {
        var parent: [String: String] = [:]
        func find(_ x: String) -> String {
            var x = x
            while let p = parent[x], p != x { parent[x] = parent[p] ?? p; x = p }
            return x
        }
        func union(_ a: String, _ b: String) {
            parent[a] = parent[a] ?? a
            parent[b] = parent[b] ?? b
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        func key(_ e: Endpoint, _ w: Wire, _ side: String) -> String {
            e == .unassigned ? "\(w.id)·\(side)" : e.description
        }
        for w in h.wires { union(key(w.from, w, "A"), key(w.to, w, "B")) }
        // In-line mated pairs pass each cavity through to the same cavity of the mate; fuses and jumpers
        // in a box join the cavities they span.
        let wired = Set(h.wires.flatMap { [$0.from, $0.to] }.map(\.description))
        for c in h.connectors {
            if let m = c.mate, let other = h.connector(m) {
                for cav in c.cavities where other.cavities.contains(where: { $0.label == cav.label }) {
                    let a = "\(c.id):\(cav.label)", b = "\(m):\(cav.label)"
                    if wired.contains(a) || wired.contains(b) { union(a, b) }
                }
            }
            for item in c.boxItems where item.kind.conducts && item.cavities.count > 1 {
                let refs = item.cavities.map { "\(c.id):\($0)" }
                for r in refs.dropFirst() { union(refs[0], r) }
            }
        }
        var groups: [String: (members: Set<String>, wires: [Wire])] = [:]
        for w in h.wires {
            let r = find(key(w.from, w, "A"))
            groups[r, default: ([], [])].wires.append(w)
            for (e, s) in [(w.from, "A"), (w.to, "B")] where e != .unassigned {
                if case .pin = e { groups[r]!.members.insert(key(e, w, s)) }
            }
        }
        var n = 0
        let nets = groups.values.map { g -> Net in
            let signals = g.wires.compactMap(\.signal).filter { !$0.isEmpty }
            let name: String
            if let best = Dictionary(grouping: signals, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key {
                name = best
            } else {
                n += 1
                name = "NET\(n)"
            }
            return Net(name: name, members: g.members.sorted(by: naturalLess), wires: g.wires.map(\.id).sorted(by: naturalLess))
        }
        // Several groups can share a signal name (e.g. two separate grounds); keep names unique.
        var seen: [String: Int] = [:]
        return nets.sorted { naturalLess($0.name, $1.name) }.map { net in
            var net = net
            seen[net.name, default: 0] += 1
            if seen[net.name]! > 1 { net.name += " (\(seen[net.name]!))" }
            return net
        }
    }

    public static func labelText(_ l: BundleLabel, _ h: Harness) -> String {
        if let t = l.text, !t.isEmpty { return t }
        switch l.placement {
        case let .connector(cid):
            let c = h.connector(cid)
            return [cid, c?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        case let .segment(sid, _):
            return "\(h.name) \(sid)"
        }
    }

    static func buildLabels(_ h: Harness) -> [LabelRow] {
        var rows = h.labels.map { l -> LabelRow in
            let loc: String = switch l.placement {
            case let .segment(sid, off): "\(sid) @ \(h.settings.units.format(off))"
            case let .connector(cid): "at \(cid)"
            }
            return LabelRow(id: l.id, text: labelText(l, h), location: loc, part: l.part?.mpn ?? "")
        }
        for w in h.wires {
            guard let m = w.markerText, !m.isEmpty else { continue }
            rows.append(LabelRow(id: "\(w.id)·A", text: m, location: "\(w.id) end A (\(w.from))", part: "wire marker"))
            rows.append(LabelRow(id: "\(w.id)·B", text: m, location: "\(w.id) end B (\(w.to))", part: "wire marker"))
        }
        return rows
    }

    static func buildTools(_ h: Harness) -> [ToolRow] {
        var byName: [String: ToolRow] = [:]
        for (ref, part) in allParts(h) {
            guard let tool = part.crimpTool, !tool.isEmpty else { continue }
            byName[tool, default: ToolRow(name: tool, kind: "Crimp tool", partNumber: tool, usedFor: [])].usedFor.append("\(part.mpn) (\(ref))")
        }
        for t in h.tools {
            byName[t.name] = ToolRow(name: t.name, kind: t.kind.rawValue, partNumber: t.partNumber,
                                     usedFor: (byName[t.name]?.usedFor ?? []) + (t.notes.isEmpty ? [] : [t.notes]))
        }
        return byName.values.sorted { $0.name < $1.name }.map { row in
            var row = row
            // Collapse "same part in many cavities" into one entry with a count.
            let counts = Dictionary(grouping: row.usedFor) { $0.components(separatedBy: " (").first ?? $0 }
            row.usedFor = counts.keys.sorted().map { k in counts[k]!.count > 1 ? "\(k) ×\(counts[k]!.count)" : counts[k]![0] }
            return row
        }
    }
}

/// "C2" < "C10", "1" < "12".
public func naturalLess(_ a: String, _ b: String) -> Bool {
    a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
}

private func fmt(_ v: Double) -> String { String(format: "%g", (v * 100).rounded() / 100) }

extension Issue.Severity {
    var rank: Int {
        switch self { case .error: 0; case .warning: 1; case .info: 2 }
    }
}


/// Dictionary lookups by id, built once per analysis. `Harness.connector(_:)` and friends scan their arrays,
/// which made analysing a 600-wire harness take about a quarter of a second on every edit.
struct HarnessLookup {
    private let connectors: [EntityID: Connector]
    private let splices: [EntityID: Splice]
    private let wires: [EntityID: Wire]
    private let segments: [EntityID: Segment]

    init(_ h: Harness) {
        connectors = Dictionary(h.connectors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        splices = Dictionary(h.splices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        wires = Dictionary(h.wires.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        segments = Dictionary(h.segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func connector(_ id: EntityID) -> Connector? { connectors[id] }
    func splice(_ id: EntityID) -> Splice? { splices[id] }
    func wire(_ id: EntityID) -> Wire? { wires[id] }
    func segment(_ id: EntityID) -> Segment? { segments[id] }

    func cavity(_ e: Endpoint) -> Cavity? {
        guard case let .pin(c, cav) = e else { return nil }
        return connectors[c]?.cavities.first { $0.label == cav }
    }
}
