import Foundation

// Fuse and relay boxes, loose pins, in-line mated pairs and pass-through wiring.

public extension Harness {
    /// A fuse holder with `fuses` positions. Fuse Fk spans cavities 2k-1 and 2k (line side, load side).
    @discardableResult
    mutating func addFuseBox(at p: Point2D, fuses: Int, rating: String? = nil, part: PartRef? = nil) -> EntityID {
        let n = max(1, fuses)
        let cid = placeBlank(kind: .fuseBox, cavities: 2 * n, at: p, part: part)
        updateConnector(cid) { c in
            c.boxItems = (1...n).map { k in
                BoxItem(id: "F\(k)", kind: .fuse, rating: rating, cavities: [String(2 * k - 1), String(2 * k)])
            }
        }
        return cid
    }

    /// An ISO mini relay socket: cavities 30, 85, 86, 87 and 87a with the relay R1 plugged in.
    @discardableResult
    mutating func addRelay(at p: Point2D, changeover: Bool = true, rating: String? = nil, part: PartRef? = nil) -> EntityID {
        let labels = changeover ? ["30", "85", "86", "87", "87a"] : ["30", "85", "86", "87"]
        let cid = placeBlank(kind: .relay, cavities: labels.count, at: p, part: part)
        updateConnector(cid) { c in
            c.cavities = labels.map { Cavity(label: $0) }
            for i in c.cavities.indices {
                c.cavities[i].signal = ["30": "COMMON", "85": "COIL −", "86": "COIL +", "87": "NO", "87a": "NC"][c.cavities[i].label]
            }
            c.boxItems = [BoxItem(id: "R1", kind: .relay, rating: rating, cavities: labels)]
        }
        return cid
    }

    /// Terminated pins with no housing, to be pinned into a mating part later (a factory connector, a panel).
    @discardableResult
    mutating func addLoosePins(at p: Point2D, count: Int, terminal: PartRef? = nil) -> EntityID {
        let cid = placeBlank(kind: .loosePins, cavities: max(1, count), at: p, part: nil, prefix: "P")
        if let terminal { updateConnector(cid) { c in for i in c.cavities.indices { c.cavities[i].terminal = terminal } } }
        return cid
    }

    /// Two connectors mated in line inside this harness, drawn side by side: C5F (female) and C5M (male).
    /// Each cavity passes through to the same cavity of the other half.
    @discardableResult
    mutating func addMatedPair(at p: Point2D, cavities: Int, female: PartRef? = nil, male: PartRef? = nil) -> (EntityID, EntityID) {
        let base = nextID(prefix: "C")
        let f = base + "F", m = base + "M"
        for (id, gender, part, dx) in [(f, Gender.female, female, -30.0), (m, Gender.male, male, 30.0)] {
            let nid = nextID(prefix: "N")
            var c = Connector(id: id, kind: .housing, part: part, gender: gender, nodeID: nid, cavityCount: max(1, cavities))
            c.mate = id == f ? m : f
            connectors.append(c)
            nodes.append(TopologyNode(id: nid, kind: .connector, label: id, position: Point2D(p.x + dx, p.y)))
        }
        return (f, m)
    }

    /// Mates two existing connectors (or unmates when `b` is nil).
    mutating func setMate(_ a: EntityID, _ b: EntityID?) {
        if let old = connector(a)?.mate { updateConnector(old) { $0.mate = nil } }
        updateConnector(a) { $0.mate = b }
        if let b {
            if let old = connector(b)?.mate, old != a { updateConnector(old) { $0.mate = nil } }
            updateConnector(b) { $0.mate = a }
        }
    }

    /// Wires every cavity of `a` to the cavity of `b` with the same label (a T-harness or pass-through:
    /// IPC IN ↔ IPC OUT). Cavities that already carry a wire are skipped unless `includeUsed`.
    /// Returns the new wire ids.
    @discardableResult
    mutating func passThrough(from a: EntityID, to b: EntityID, size: WireSize, color: WireColor,
                              insulation: String = "TXL", includeUsed: Bool = false, matchByOrder: Bool = false) throws -> [EntityID] {
        guard let ca = connector(a) else { throw EditError.notFound(a) }
        guard let cb = connector(b) else { throw EditError.notFound(b) }
        let used = Set(wires.flatMap { [$0.from, $0.to] })
        var made: [EntityID] = []
        let pairs: [(Cavity, Cavity)] = matchByOrder
            ? Array(zip(ca.cavities, cb.cavities))
            : ca.cavities.compactMap { cav in cb.cavities.first { $0.label == cav.label }.map { (cav, $0) } }
        for (x, y) in pairs {
            let from = Endpoint.pin(connector: a, cavity: x.label), to = Endpoint.pin(connector: b, cavity: y.label)
            if !includeUsed, used.contains(from) || used.contains(to) { continue }
            let id = nextID(prefix: "W")
            let signal = [x.signal, y.signal].compactMap { $0 }.first { !$0.isEmpty }
            wires.append(Wire(id: id, signal: signal, size: size, color: color, insulation: insulation, from: from, to: to))
            made.append(id)
        }
        return made
    }

    private mutating func placeBlank(kind: ConnectorKind, cavities: Int, at p: Point2D, part: PartRef?, prefix: String = "C") -> EntityID {
        let nid = nextID(prefix: "N")
        let cid = nextID(prefix: prefix)
        connectors.append(Connector(id: cid, kind: kind, part: part, nodeID: nid, cavityCount: cavities))
        nodes.append(TopologyNode(id: nid, kind: .connector, label: cid, position: p))
        return cid
    }

    private mutating func updateConnector(_ id: EntityID, _ change: (inout Connector) -> Void) {
        if let i = connectors.firstIndex(where: { $0.id == id }) { change(&connectors[i]) }
    }
}

// MARK: - Placing any component

public extension ConnectorKind {
    /// What a part is, read from its distributor category and description: a fuse holder, a relay, a ring or
    /// spade terminal, a ferrule, a quick-connect, or (anything else) a connector housing.
    static func detect(_ part: PartRef?, libraryCategory: String? = nil) -> ConnectorKind {
        guard let part else { return .housing }
        if libraryCategory == "terminal" || libraryCategory == "seal" { return looseTerminal(in: text(part)) ?? .ringTerminal }
        let t = text(part)
        if t.range(of: #"fuse ?(holder|block|box|panel|carrier|base)|power distribution"#, options: .regularExpression) != nil { return .fuseBox }
        if t.contains("relay") { return .relay }
        return looseTerminal(in: t) ?? .housing
    }

    private static func text(_ p: PartRef) -> String {
        [p.category, p.description, p.mpn].compactMap { $0 }.joined(separator: " ").lowercased()
    }

    private static func looseTerminal(in t: String) -> ConnectorKind? {
        if t.range(of: #"ring (terminal|tongue|lug)|\bring\b.*terminal"#, options: .regularExpression) != nil { return .ringTerminal }
        if t.range(of: #"spade|fork terminal"#, options: .regularExpression) != nil { return .spadeTerminal }
        if t.range(of: #"ferrule"#, options: .regularExpression) != nil { return .ferrule }
        if t.range(of: #"quick[- ]?(dis)?connect|faston"#, options: .regularExpression) != nil { return .quickConnect }
        return nil
    }
}

public extension Harness {
    /// Places any component: a connector, fuse holder, relay, terminal or loose pins, laid out for its kind.
    @discardableResult
    mutating func placeComponent(part: PartRef?, kind: ConnectorKind, at p: Point2D, configuration: LibraryPart? = nil) -> EntityID {
        switch kind {
        case .fuseBox where part == nil:
            return addFuseBox(at: p, fuses: 3)
        case .relay:
            guard let part else { return addRelay(at: p) }
            // A relay socket is the housing; a relay on its own is the plug-in item of a socket with no part yet.
            let text = [part.category, part.description].compactMap { $0 }.joined(separator: " ").lowercased()
            let isSocket = text.range(of: #"socket|base|holder|housing"#, options: .regularExpression) != nil
            let id = placeConnector(part: isSocket ? part : nil, kind: .relay, at: p, configuration: configuration)
            guard let i = connectors.firstIndex(where: { $0.id == id }) else { return id }
            if !isSocket, let n = part.positionCount, n != connectors[i].cavities.count {
                connectors[i].cavities = (1...max(1, n)).map { Cavity(label: String($0)) }
            }
            // 4 or 5 terminals: the ISO names (30, 85, 86, 87, 87a).
            if configuration == nil, [4, 5].contains(connectors[i].cavities.count) {
                let labels = connectors[i].cavities.count == 5 ? ["30", "85", "86", "87", "87a"] : ["30", "85", "86", "87"]
                connectors[i].cavities = labels.map { Cavity(label: $0) }
            }
            connectors[i].boxItems = [BoxItem(id: "R1", kind: .relay, part: isSocket ? nil : part, cavities: connectors[i].cavities.map(\.label))]
            return id
        case .loosePins:
            return addLoosePins(at: p, count: part?.positionCount ?? 2, terminal: part)
        default:
            return placeConnector(part: part, kind: kind, at: p, configuration: configuration)
        }
    }
}
