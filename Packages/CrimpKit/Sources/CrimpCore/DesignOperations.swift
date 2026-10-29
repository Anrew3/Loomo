import Foundation

public extension Harness {
    // MARK: Parts

    /// Items that use a part (designators, "C1:3" for cavity parts).
    func usages(of part: PartRef) -> [EntityID] {
        HarnessAnalysis.allParts(self).filter { $0.1.isSamePart(as: part) }.map(\.0)
    }

    /// Replaces a part everywhere it is used (switch terminal type, swap a generic part for an exact one). Returns the number of places changed.
    @discardableResult
    mutating func replacePart(_ old: PartRef, with new: PartRef) -> Int {
        var count = 0
        func swap(_ p: inout PartRef?) {
            if let current = p, current.isSamePart(as: old) { p = new; count += 1 }
        }
        func swap(_ p: inout PartRef) {
            if p.isSamePart(as: old) { p = new; count += 1 }
        }
        for i in connectors.indices {
            swap(&connectors[i].part)
            for j in connectors[i].accessories.indices { swap(&connectors[i].accessories[j].part) }
            for j in connectors[i].cavities.indices {
                swap(&connectors[i].cavities[j].terminal)
                swap(&connectors[i].cavities[j].seal)
                swap(&connectors[i].cavities[j].plug)
            }
        }
        for i in wires.indices { swap(&wires[i].part) }
        for i in cables.indices { swap(&cables[i].part) }
        for i in splices.indices { swap(&splices[i].part); swap(&splices[i].heatShrink) }
        for i in coverings.indices { swap(&coverings[i].part) }
        for i in labels.indices { swap(&labels[i].part) }
        for i in nodes.indices { swap(&nodes[i].part) }
        return count
    }

    // MARK: Twists and cables

    @discardableResult
    mutating func twist(_ wireIDs: [EntityID], layLengthMM: Double = 25) -> EntityID? {
        guard wireIDs.count >= 2 else { return nil }
        untwist(wireIDs)
        let id = nextID(prefix: "TW")
        twists.append(Twist(id: id, wireIDs: wireIDs, layLengthMM: layLengthMM))
        return id
    }

    /// Removes the given wires from any twist; twists left with fewer than two wires are deleted.
    mutating func untwist(_ wireIDs: [EntityID]) {
        let remove = Set(wireIDs)
        for i in twists.indices { twists[i].wireIDs.removeAll { remove.contains($0) } }
        twists.removeAll { $0.wireIDs.count < 2 }
    }

    @discardableResult
    mutating func makeCable(from wireIDs: [EntityID], shielded: Bool = false) -> EntityID {
        let id = nextID(prefix: "CB")
        let cores = wires.filter { wireIDs.contains($0.id) }
        let jacket = cores.isEmpty ? 5 : 1.25 * (cores.map { $0.outerDiameterMM * $0.outerDiameterMM }.reduce(0, +)).squareRoot() + 1
        cables.append(Cable(id: id, name: "\(cores.count)-core cable", shielded: shielded, jacketODMM: (jacket * 10).rounded() / 10))
        for i in wires.indices where wireIDs.contains(wires[i].id) { wires[i].cableID = id }
        return id
    }

    mutating func dissolveCable(_ id: EntityID) {
        for i in wires.indices where wires[i].cableID == id { wires[i].cableID = nil }
        cables.removeAll { $0.id == id }
    }

    // MARK: Remapping

    /// Moves every wire end on connector `from` to connector `to`. `cavityMap` renames cavities; unmapped cavities keep their label.
    /// Returns wire ends whose target cavity does not exist.
    @discardableResult
    mutating func remapConnections(from: EntityID, to: EntityID, cavityMap: [String: String] = [:]) -> [WireEnd] {
        let targetLabels = Set(connector(to)?.cavities.map(\.label) ?? [])
        var missing: [WireEnd] = []
        for end in allWireEnds {
            guard case let .pin(c, cav)? = endpoint(of: end), c == from else { continue }
            let newCav = cavityMap[cav] ?? cav
            setEndpoint(.pin(connector: to, cavity: newCav), for: end)
            if !targetLabels.contains(newCav) { missing.append(end) }
        }
        return missing
    }

    // MARK: Formboard layout

    /// Moves nodes so every segment is drawn at its true length (`pointsPerMM` on the canvas),
    /// keeping each segment's current direction. Harness topologies are trees; extra edges in a loop keep their old geometry.
    mutating func layoutToScale(pointsPerMM: Double = 0.5) {
        guard let root = connectors.first(where: { $0.nodeID != nil })?.nodeID ?? nodes.first?.id,
              let rootNode = node(root) else { return }
        var placed: [EntityID: Point2D] = [root: rootNode.position]
        var queue = [root]
        let original = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
        while !queue.isEmpty {
            let u = queue.removeFirst()
            for s in segments where s.nodeA == u || s.nodeB == u {
                let v = s.nodeA == u ? s.nodeB : s.nodeA
                guard placed[v] == nil, let pu = placed[u], let ou = original[u], let ov = original[v] else { continue }
                var dx = ov.x - ou.x, dy = ov.y - ou.y
                let len = hypot(dx, dy)
                if len < 1e-6 { dx = 1; dy = 0 } else { dx /= len; dy /= len }
                placed[v] = Point2D(pu.x + dx * s.lengthMM * pointsPerMM, pu.y + dy * s.lengthMM * pointsPerMM)
                queue.append(v)
            }
        }
        for i in nodes.indices { if let p = placed[nodes[i].id] { nodes[i].position = p } }
    }
}

// MARK: - Copy and paste

/// A copied piece of a harness: nodes, the segments between them and everything attached.
public struct HarnessClip: Codable, Hashable, Sendable {
    public var nodes: [TopologyNode] = []
    public var segments: [Segment] = []
    public var connectors: [Connector] = []
    public var splices: [Splice] = []
    public var wires: [Wire] = []
    public var cables: [Cable] = []
    public var twists: [Twist] = []
    public var coverings: [Covering] = []
    public var labels: [BundleLabel] = []

    public static let pasteboardType = "com.loomo.harness-clip"
}

public extension Harness {
    /// Copies the given nodes, the segments between them, the connectors and splices on them,
    /// and the wires whose both ends are inside. Coverings and labels come along for copied segments.
    func copySection(nodeIDs: Set<EntityID>) -> HarnessClip {
        var clip = HarnessClip()
        clip.nodes = nodes.filter { nodeIDs.contains($0.id) }
        clip.segments = segments.filter { nodeIDs.contains($0.nodeA) && nodeIDs.contains($0.nodeB) }
        clip.connectors = connectors.filter { $0.nodeID.map(nodeIDs.contains) ?? false }
        clip.splices = splices.filter { $0.nodeID.map(nodeIDs.contains) ?? false }
        let cons = Set(clip.connectors.map(\.id)), spl = Set(clip.splices.map(\.id))
        func inside(_ e: Endpoint) -> Bool {
            switch e {
            case let .pin(c, _): return cons.contains(c)
            case let .splice(s): return spl.contains(s)
            case .unassigned: return true
            }
        }
        clip.wires = wires.filter { inside($0.from) && inside($0.to) }
        let wireIDs = Set(clip.wires.map(\.id))
        clip.cables = cables.filter { c in clip.wires.contains { $0.cableID == c.id } }
        clip.twists = twists.filter { $0.wireIDs.allSatisfy(wireIDs.contains) }
        let segIDs = Set(clip.segments.map(\.id))
        clip.coverings = coverings.compactMap { c in
            var c = c
            c.segmentIDs = c.segmentIDs.filter(segIDs.contains)
            return c.segmentIDs.isEmpty ? nil : c
        }
        clip.labels = labels.filter {
            switch $0.placement {
            case let .segment(s, _): return segIDs.contains(s)
            case let .connector(c): return cons.contains(c)
            }
        }
        return clip
    }

    /// Pastes a clip with fresh ids, offset on the canvas. Returns the new node ids.
    @discardableResult
    mutating func paste(_ clip: HarnessClip, offset: Point2D = Point2D(40, 40)) -> [EntityID] {
        var map: [EntityID: EntityID] = [:]
        func fresh(_ old: EntityID, _ prefix: String) -> EntityID {
            let id = nextID(prefix: prefix)
            map[old] = id
            return id
        }
        func prefix(of id: EntityID) -> String { String(id.prefix { !$0.isNumber }) }

        var newNodes: [EntityID] = []
        for n in clip.nodes {
            var n = n
            n.id = fresh(n.id, "N")
            n.position = Point2D(n.position.x + offset.x, n.position.y + offset.y)
            nodes.append(n)
            newNodes.append(n.id)
        }
        for c in clip.connectors {
            var c = c
            c.id = fresh(c.id, prefix(of: c.id).isEmpty ? "C" : prefix(of: c.id))
            c.nodeID = c.nodeID.flatMap { map[$0] }
            connectors.append(c)
        }
        // Mates travel with the clip only when both halves were copied.
        for i in connectors.indices where connectors[i].mate != nil && map.values.contains(connectors[i].id) {
            connectors[i].mate = connectors[i].mate.flatMap { map[$0] }
        }
        for s in clip.splices {
            var s = s
            s.id = fresh(s.id, "SP")
            s.nodeID = s.nodeID.flatMap { map[$0] }
            splices.append(s)
        }
        for s in clip.segments {
            var s = s
            s.id = fresh(s.id, "S")
            s.nodeA = map[s.nodeA] ?? s.nodeA
            s.nodeB = map[s.nodeB] ?? s.nodeB
            segments.append(s)
        }
        for c in clip.cables {
            var c = c
            c.id = fresh(c.id, "CB")
            cables.append(c)
        }
        func remap(_ e: Endpoint) -> Endpoint {
            switch e {
            case let .pin(c, cav): return .pin(connector: map[c] ?? c, cavity: cav)
            case let .splice(s): return .splice(map[s] ?? s)
            case .unassigned: return .unassigned
            }
        }
        for w in clip.wires {
            var w = w
            w.id = fresh(w.id, "W")
            w.from = remap(w.from)
            w.to = remap(w.to)
            w.cableID = w.cableID.flatMap { map[$0] }
            wires.append(w)
        }
        for t in clip.twists {
            var t = t
            t.id = fresh(t.id, "TW")
            t.wireIDs = t.wireIDs.compactMap { map[$0] }
            twists.append(t)
        }
        for c in clip.coverings {
            var c = c
            c.id = fresh(c.id, "CV")
            c.segmentIDs = c.segmentIDs.compactMap { map[$0] }
            coverings.append(c)
        }
        for l in clip.labels {
            var l = l
            l.id = fresh(l.id, "L")
            switch l.placement {
            case let .segment(s, off): l.placement = .segment(map[s] ?? s, offsetMM: off)
            case let .connector(c): l.placement = .connector(map[c] ?? c)
            }
            labels.append(l)
        }
        return newNodes
    }
}

// MARK: - Group editing (multi-selection on the drawing)

public extension Harness {
    /// Moves nodes and annotations together by an offset.
    mutating func move(nodes nodeIDs: Set<EntityID>, annotations annotationIDs: Set<EntityID>, from origins: [EntityID: Point2D], by dx: Double, _ dy: Double) {
        for i in nodes.indices where nodeIDs.contains(nodes[i].id) {
            if let o = origins[nodes[i].id] { nodes[i].position = Point2D(o.x + dx, o.y + dy) }
        }
        for i in annotations.indices where annotationIDs.contains(annotations[i].id) {
            if let o = origins[annotations[i].id] { annotations[i].x = o.x + dx; annotations[i].y = o.y + dy }
        }
    }

    /// Deletes any mix of nodes (with the connector or splice on them), segments, connectors, splices,
    /// wires, coverings, labels and annotations. Wire ends left without a home become unassigned.
    mutating func delete(_ ids: Set<EntityID>) {
        var nodeIDs = ids.filter { node($0) != nil }
        for c in connectors where ids.contains(c.id) { if let n = c.nodeID { nodeIDs.insert(n) } }
        for s in splices where ids.contains(s.id) { if let n = s.nodeID { nodeIDs.insert(n) } }
        let goneConnectors = Set(connectors.filter { ids.contains($0.id) || ($0.nodeID.map(nodeIDs.contains) ?? false) }.map(\.id))
        let goneSplices = Set(splices.filter { ids.contains($0.id) || ($0.nodeID.map(nodeIDs.contains) ?? false) }.map(\.id))
        let goneSegments = Set(segments.filter { ids.contains($0.id) || nodeIDs.contains($0.nodeA) || nodeIDs.contains($0.nodeB) }.map(\.id))

        for i in wires.indices {
            for side in [WireEnd.Side.a, .b] {
                let e = side == .a ? wires[i].from : wires[i].to
                let gone: Bool = switch e {
                case let .pin(c, _): goneConnectors.contains(c)
                case let .splice(s): goneSplices.contains(s)
                case .unassigned: false
                }
                if gone { if side == .a { wires[i].from = .unassigned } else { wires[i].to = .unassigned } }
            }
        }
        wires.removeAll { ids.contains($0.id) }
        let goneWires = ids
        for i in twists.indices { twists[i].wireIDs.removeAll { goneWires.contains($0) } }
        twists.removeAll { $0.wireIDs.count < 2 }
        connectors.removeAll { goneConnectors.contains($0.id) }
        for i in connectors.indices where connectors[i].mate.map(goneConnectors.contains) == true { connectors[i].mate = nil }
        splices.removeAll { goneSplices.contains($0.id) }
        segments.removeAll { goneSegments.contains($0.id) }
        nodes.removeAll { nodeIDs.contains($0.id) }
        for i in coverings.indices { coverings[i].segmentIDs.removeAll { goneSegments.contains($0) } }
        coverings.removeAll { ids.contains($0.id) || $0.segmentIDs.isEmpty }
        labels.removeAll { l in
            if ids.contains(l.id) { return true }
            switch l.placement {
            case let .segment(s, _): return goneSegments.contains(s)
            case let .connector(c): return goneConnectors.contains(c)
            }
        }
        annotations.removeAll { ids.contains($0.id) }
        cables.removeAll { ids.contains($0.id) }
        for i in notes.indices { notes[i].attachedTo.removeAll { ids.contains($0) || goneConnectors.contains($0) || goneSplices.contains($0) } }
        let gone = ids.union(goneConnectors).union(goneSplices).union(goneSegments)
        acceptedIssues.removeAll { a in gone.contains(a.subject) || gone.contains(String(a.subject.split(separator: ":").first ?? "")) }
    }

    /// Splits a segment at `t` (0…1 along it) with a new breakout node; coverings and labels follow.
    /// Returns the new node id.
    @discardableResult
    mutating func splitSegment(_ sid: EntityID, at t: Double, kind: NodeKind = .breakout) -> EntityID? {
        guard let si = segments.firstIndex(where: { $0.id == sid }),
              let a = node(segments[si].nodeA)?.position, let b = node(segments[si].nodeB)?.position else { return nil }
        let t = min(max(t, 0.05), 0.95)
        let seg = segments[si]
        let nid = nextID(prefix: "N")
        nodes.append(TopologyNode(id: nid, kind: kind, label: nextID(prefix: kind == .clip ? "CL" : "BO"),
                                  position: Point2D(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)))
        let firstLen = (seg.lengthMM * t).rounded()
        segments[si].nodeB = nid
        segments[si].lengthMM = firstLen
        let newID = nextID(prefix: "S")
        segments.append(Segment(id: newID, nodeA: nid, nodeB: seg.nodeB, lengthMM: seg.lengthMM - firstLen))
        for i in coverings.indices where coverings[i].segmentIDs.contains(sid) { coverings[i].segmentIDs.append(newID) }
        for i in labels.indices {
            if case let .segment(s, off) = labels[i].placement, s == sid, off > firstLen {
                labels[i].placement = .segment(newID, offsetMM: off - firstLen)
            }
        }
        return nid
    }

    /// Places a connector for a part at a canvas point: positions and gender from the part when known,
    /// and the library's design configuration (contacts, plugs, wedgelock…) when one exists.
    @discardableResult
    mutating func placeConnector(part: PartRef?, kind: ConnectorKind = .housing, at p: Point2D, configuration: LibraryPart? = nil) -> EntityID {
        let nid = nextID(prefix: "N")
        let cid = nextID(prefix: kind.isLooseTerminal ? "T" : "C")
        let ways = kind.isLooseTerminal ? 1 : (configuration?.cavityCount ?? part?.positionCount ?? 2)
        var c = Connector(id: cid, name: "", kind: kind, part: part, nodeID: nid, cavityCount: ways)
        if let g = part?.contactGender?.lowercased() {
            if g.hasPrefix("f") || g.contains("socket") { c.gender = .female }
            if g.hasPrefix("m") || g.contains("pin") { c.gender = .male }
        }
        if kind.isLooseTerminal, let part { c.cavities[0].terminal = part }
        if let configuration { c.apply(configuration, usedCavities: []) }
        // A count on the part itself (confirmed in the place sheet or read from distributors) beats a library count.
        if !kind.isLooseTerminal, let n = part?.positionCount, n > 0, n != c.cavities.count {
            if n > c.cavities.count {
                c.cavities += (c.cavities.count + 1...n).map { Cavity(label: String($0)) }
            } else {
                c.cavities.removeLast(c.cavities.count - n)
            }
        }
        connectors.append(c)
        nodes.append(TopologyNode(id: nid, kind: .connector, label: cid, position: p))
        return cid
    }
}

// MARK: - Price refresh

public extension Harness {
    /// Normalised MPN used to match distributor results ("DT06-4S" == "dt064s").
    static func normalizedMPN(_ mpn: String) -> String {
        mpn.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Distinct purchasable MPNs in the design (generic placeholders excluded).
    var purchasableMPNs: [String] {
        var seen: Set<String> = []
        return HarnessAnalysis.allParts(self).map(\.1).filter { !$0.isGeneric && $0.mpn.count >= 2 && $0.mpn != "—" }
            .map(\.mpn).filter { seen.insert(Self.normalizedMPN($0)).inserted }
    }

    /// Sets the unit price on every part reference whose MPN has a new price. Returns the number of references changed.
    @discardableResult
    mutating func updatePrices(_ prices: [String: Double]) -> Int {
        let byNorm = Dictionary(prices.map { (Self.normalizedMPN($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        var count = 0
        func update(_ p: inout PartRef?) {
            guard var part = p, let price = byNorm[Self.normalizedMPN(part.mpn)], part.unitPrice != price else { return }
            part.unitPrice = price
            p = part
            count += 1
        }
        func update(_ p: inout PartRef) {
            var o: PartRef? = p
            update(&o)
            if let o { p = o }
        }
        for i in connectors.indices {
            update(&connectors[i].part)
            for j in connectors[i].accessories.indices { update(&connectors[i].accessories[j].part) }
            for j in connectors[i].cavities.indices {
                update(&connectors[i].cavities[j].terminal)
                update(&connectors[i].cavities[j].seal)
                update(&connectors[i].cavities[j].plug)
            }
        }
        for i in wires.indices { update(&wires[i].part) }
        for i in cables.indices { update(&cables[i].part) }
        for i in splices.indices { update(&splices[i].part); update(&splices[i].heatShrink) }
        for i in coverings.indices { update(&coverings[i].part) }
        for i in labels.indices { update(&labels[i].part) }
        for i in nodes.indices { update(&nodes[i].part) }
        for i in bomExtraLines.indices { update(&bomExtraLines[i].part) }
        return count
    }
}

// MARK: - Building blocks for scripted editing (CLI, MCP)

public extension Harness {
    /// The drawing node for a connector, splice or node id ("C1", "SP1", "N3").
    func nodeID(for ref: EntityID) -> EntityID? {
        if node(ref) != nil { return ref }
        if let c = connector(ref) { return c.nodeID }
        if let s = splice(ref) { return s.nodeID }
        return nil
    }

    @discardableResult
    mutating func addNode(_ kind: NodeKind, at p: Point2D, label: String = "") -> EntityID {
        let id = nextID(prefix: "N")
        nodes.append(TopologyNode(id: id, kind: kind, label: label, position: p))
        return id
    }

    /// Adds a splice on its own node, or on an existing node (several splices can share one junction).
    @discardableResult
    mutating func addSplice(id: EntityID? = nil, kind: SpliceKind = .ultrasonic, at p: Point2D, onNode existing: EntityID? = nil) -> EntityID {
        let sid = id ?? nextID(prefix: "SP")
        if let existing, let i = nodes.firstIndex(where: { $0.id == existing }) {
            nodes[i].label = nodes[i].label.isEmpty ? sid : nodes[i].label + " · " + sid
            if nodes[i].kind == .breakout { nodes[i].kind = .splice }
            splices.append(Splice(id: sid, kind: kind, nodeID: existing))
        } else {
            splices.append(Splice(id: sid, kind: kind, nodeID: addNode(.splice, at: p, label: sid)))
        }
        return sid
    }

    /// Adds a bundle segment between two nodes (or the nodes of two connectors/splices).
    /// With no length, the drawn distance is used.
    mutating func addSegment(from a: EntityID, to b: EntityID, lengthMM: Double? = nil) throws -> EntityID {
        guard let na = nodeID(for: a) else { throw EditError.notFound(a) }
        guard let nb = nodeID(for: b) else { throw EditError.notFound(b) }
        guard na != nb else { throw EditError.invalid("\(a) and \(b) are at the same node") }
        if let s = segments.first(where: { Set([$0.nodeA, $0.nodeB]) == Set([na, nb]) }) {
            throw EditError.invalid("\(s.id) already joins \(a) and \(b)")
        }
        let length = lengthMM ?? {
            guard let pa = node(na)?.position, let pb = node(nb)?.position else { return 100 }
            return max(10, (hypot(pa.x - pb.x, pa.y - pb.y) / 10).rounded() * 10)
        }()
        let id = nextID(prefix: "S")
        segments.append(Segment(id: id, nodeA: na, nodeB: nb, lengthMM: length))
        return id
    }
}

public enum EditError: LocalizedError, Equatable {
    case notFound(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(id): "Nothing called \(id) in this harness"
        case let .invalid(why): why
        }
    }
}
