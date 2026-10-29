import Foundation

/// One end of a wire: side A is `Wire.from`, side B is `Wire.to`.
public struct WireEnd: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Side: String, Codable, Sendable { case a, b }
    public var wireID: EntityID
    public var side: Side

    public init(_ wireID: EntityID, _ side: Side) {
        self.wireID = wireID
        self.side = side
    }

    public var description: String { "\(wireID)·\(side.rawValue.uppercased())" }
}

/// Pinout editing operations. They are pure value edits, so the store's undo history captures each one as a single step.
public extension Harness {
    var allWireEnds: [WireEnd] { wires.flatMap { [WireEnd($0.id, .a), WireEnd($0.id, .b)] } }

    func endpoint(of end: WireEnd) -> Endpoint? {
        guard let w = wires.first(where: { $0.id == end.wireID }) else { return nil }
        return end.side == .a ? w.from : w.to
    }

    mutating func setEndpoint(_ e: Endpoint, for end: WireEnd) {
        guard let i = wires.firstIndex(where: { $0.id == end.wireID }) else { return }
        if end.side == .a { wires[i].from = e } else { wires[i].to = e }
    }

    func wireEnds(at e: Endpoint) -> [WireEnd] {
        allWireEnds.filter { endpoint(of: $0) == e }
    }

    /// Moves a wire end to `target`. When the target is an occupied cavity and `swap` is true,
    /// the wire ends already there move to where `end` came from. Splices take any number of wires, so they never swap.
    mutating func place(_ end: WireEnd, at target: Endpoint, swap: Bool = true) {
        guard let origin = endpoint(of: end), origin != target else { return }
        var occupants: [WireEnd] = []
        if swap, case .pin = target { occupants = wireEnds(at: target) }
        setEndpoint(target, for: end)
        for o in occupants { setEndpoint(origin, for: o) }
    }

    mutating func unassign(_ end: WireEnd) {
        setEndpoint(.unassigned, for: end)
    }

    /// Swaps everything between two cavities of one connector (wires, signal, terminal, seal and plug), keeping the labels in place.
    mutating func swapCavities(connector cid: EntityID, _ a: String, _ b: String) {
        guard a != b, let ci = connectors.firstIndex(where: { $0.id == cid }),
              let ia = connectors[ci].cavities.firstIndex(where: { $0.label == a }),
              let ib = connectors[ci].cavities.firstIndex(where: { $0.label == b }) else { return }
        let ea = Endpoint.pin(connector: cid, cavity: a), eb = Endpoint.pin(connector: cid, cavity: b)
        let endsA = wireEnds(at: ea), endsB = wireEnds(at: eb)
        for e in endsA { setEndpoint(eb, for: e) }
        for e in endsB { setEndpoint(ea, for: e) }
        var newA = connectors[ci].cavities[ib]
        var newB = connectors[ci].cavities[ia]
        newA.label = a
        newB.label = b
        connectors[ci].cavities[ia] = newA
        connectors[ci].cavities[ib] = newB
    }

    /// Adds a wire with side A at `start` and side B unassigned, ready to be placed on another connector.
    @discardableResult
    mutating func addWire(from start: Endpoint, size: WireSize = .awg(20), color: WireColor = WireColor("BK")) -> EntityID {
        let id = nextID(prefix: "W")
        var signal: String?
        if case let .pin(c, cav) = start {
            signal = connector(c)?.cavities.first { $0.label == cav }?.signal
        }
        wires.append(Wire(id: id, signal: signal, size: size, color: color, from: start, to: .unassigned))
        return id
    }
}

// MARK: - Connecting wires between connectors

public extension Harness {
    func isOccupied(_ e: Endpoint) -> Bool {
        wires.contains { $0.from == e || $0.to == e }
    }

    /// First cavity with no wire and no plug, after `after` when given (for "Add & Next").
    func firstFreeCavity(_ connectorID: EntityID, after: String? = nil) -> String? {
        guard let c = connector(connectorID) else { return nil }
        var labels = c.cavities.map(\.label)
        if let after, let i = labels.firstIndex(of: after) { labels = Array(labels[(i + 1)...] + labels[...i]) }
        return labels.first { label in
            let cav = c.cavities.first { $0.label == label }
            return !isOccupied(.pin(connector: connectorID, cavity: label)) && cav?.plug == nil
        } ?? labels.first { !isOccupied(.pin(connector: connectorID, cavity: $0)) }
    }

    /// True when a bundle path joins the topology nodes of two endpoints.
    func hasRoute(_ a: Endpoint, _ b: Endpoint) -> Bool {
        guard let na = HarnessAnalysis.node(for: a, in: self), let nb = HarnessAnalysis.node(for: b, in: self) else { return false }
        return TopologyGraph(self).shortestPath(from: na, to: nb) != nil
    }

    /// Adds a wire between two endpoints. Sealing plugs in the two cavities are removed (a wire goes there now),
    /// the signal defaults to the cavity signal, and a bundle segment is added between the connectors when
    /// `addBundleIfMissing` is set and no route exists yet. Returns the new wire's id.
    @discardableResult
    mutating func connect(_ a: Endpoint, _ b: Endpoint, size: WireSize = .awg(20), color: WireColor = WireColor("BK"),
                          signal: String? = nil, insulation: String = "TXL", addBundleIfMissing: Bool = true,
                          doubleCrimp: Bool = false) -> EntityID {
        if addBundleIfMissing, !hasRoute(a, b),
           let na = HarnessAnalysis.node(for: a, in: self), let nb = HarnessAnalysis.node(for: b, in: self), na != nb,
           let pa = node(na)?.position, let pb = node(nb)?.position {
            let length = max(10, (hypot(pa.x - pb.x, pa.y - pb.y) / 10).rounded() * 10)
            segments.append(Segment(id: nextID(prefix: "S"), nodeA: na, nodeB: nb, lengthMM: length))
        }
        for e in [a, b] {
            guard case let .pin(c, cav) = e, let ci = connectors.firstIndex(where: { $0.id == c }),
                  let k = connectors[ci].cavities.firstIndex(where: { $0.label == cav }) else { continue }
            connectors[ci].cavities[k].plug = nil
            // A wire going into an occupied cavity is a double crimp when the caller says so.
            if doubleCrimp, isOccupied(e) { connectors[ci].cavities[k].doubleCrimp = true }
        }
        let sig = signal ?? cavity(a)?.signal ?? cavity(b)?.signal
        let id = nextID(prefix: "W")
        wires.append(Wire(id: id, signal: (sig?.isEmpty ?? true) ? nil : sig, size: size, color: color,
                          insulation: insulation, from: a, to: b))
        return id
    }
}


// MARK: - Renaming connectors

public extension Harness {
    /// Renames a connector everywhere it is referenced (wires, nodes, labels, notes). Returns false if `new` is taken.
    @discardableResult
    mutating func renameConnector(_ old: EntityID, to new: EntityID) -> Bool {
        guard old != new, connector(new) == nil, let i = connectors.firstIndex(where: { $0.id == old }) else { return false }
        connectors[i].id = new
        for n in nodes.indices where nodes[n].label == old { nodes[n].label = new }
        remapConnections(from: old, to: new)
        for l in labels.indices where labels[l].placement == .connector(old) { labels[l].placement = .connector(new) }
        for c in connectors.indices where connectors[c].mate == old { connectors[c].mate = new }
        // Accepted deviations are keyed by subject ("C3", "C3:2") and quote the designator in their message.
        for i in acceptedIssues.indices {
            if acceptedIssues[i].subject == old { acceptedIssues[i].subject = new }
            else if acceptedIssues[i].subject.hasPrefix(old + ":") { acceptedIssues[i].subject = new + acceptedIssues[i].subject.dropFirst(old.count) }
            acceptedIssues[i].message = acceptedIssues[i].message.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: old))\\b", with: new, options: .regularExpression)
        }
        for n in notes.indices { notes[n].attachedTo = notes[n].attachedTo.map { $0 == old ? new : $0 } }
        return true
    }

    /// Renames one cavity ("1" → "A"); every wire end, accepted deviation and face cavity on it follows.
    @discardableResult
    mutating func renameCavity(_ connectorID: EntityID, _ old: String, to new: String) -> Bool {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, old != new, let ci = connectors.firstIndex(where: { $0.id == connectorID }),
              let k = connectors[ci].cavities.firstIndex(where: { $0.label == old }),
              !connectors[ci].cavities.contains(where: { $0.label == new }) else { return false }
        connectors[ci].cavities[k].label = new
        for i in wires.indices {
            if wires[i].from == .pin(connector: connectorID, cavity: old) { wires[i].from = .pin(connector: connectorID, cavity: new) }
            if wires[i].to == .pin(connector: connectorID, cavity: old) { wires[i].to = .pin(connector: connectorID, cavity: new) }
        }
        if var face = connectors[ci].faceLayout, let f = face.cavities.firstIndex(where: { $0.label == old }) {
            face.cavities[f].label = new
            connectors[ci].faceLayout = face
        }
        for i in connectors[ci].boxItems.indices {
            connectors[ci].boxItems[i].cavities = connectors[ci].boxItems[i].cavities.map { $0 == old ? new : $0 }
        }
        for i in acceptedIssues.indices where acceptedIssues[i].subject == "\(connectorID):\(old)" {
            acceptedIssues[i].subject = "\(connectorID):\(new)"
        }
        return true
    }

    /// Renumbers housings C1, C2, C3… in their current order (loose terminals keep their T numbers).
    mutating func renumberConnectors(prefix: String = "C") {
        let order = connectors.filter { !$0.kind.isLooseTerminal }.map(\.id).sorted(by: naturalLess)
        // Two passes through temporary names so C2 → C1 cannot collide with an existing C1.
        for (i, id) in order.enumerated() { renameConnector(id, to: "__tmp\(i)") }
        for i in order.indices { renameConnector("__tmp\(i)", to: "\(prefix)\(i + 1)") }
    }
}
