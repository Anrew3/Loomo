import Foundation

/// A pin anywhere in the system, e.g. "H1/C1:3" or "ECU/J1:12".
public struct SystemPin: Hashable, Sendable, CustomStringConvertible, Comparable {
    public var connector: ConnectorRef
    public var pin: String

    public init(_ connector: ConnectorRef, _ pin: String) {
        self.connector = connector
        self.pin = pin
    }

    public var key: String { "\(connector.description):\(pin)" }
    public var description: String { key }
    public static func < (a: SystemPin, b: SystemPin) -> Bool { naturalLess(a.key, b.key) }
}

public struct SystemNet: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    /// Pin keys on harness connectors and device connectors.
    public var pins: [String]
    /// Device pins only — where the signal starts or ends.
    public var devicePins: [String]
    /// "H1/W3" style wire references.
    public var wires: [String]
    public var harnesses: [EntityID]
}

/// One hop of a signal trace: through a wire, a splice, or a mate.
public struct TraceStep: Hashable, Sendable, Identifiable {
    public enum Via: Hashable, Sendable {
        case wire(harness: EntityID, wire: EntityID)
        case mate(EntityID)
    }
    public var id: String { "\(from)>\(to)" }
    public var from: String
    public var to: String
    public var via: Via
    /// Wire colour, size and length for wire hops; connector names for mates.
    public var detail: String
    public var depth: Int
}

public struct SystemBOMLine: Identifiable, Hashable, Sendable {
    public var id: String { line.id }
    public var line: BOMLine
    /// Quantity contributed by each harness instance (already multiplied by its quantity), or "Devices".
    public var breakdown: [String: Double]
}

public struct SystemAnalysis: Sendable {
    public let harnessAnalyses: [EntityID: HarnessAnalysis]
    public let nets: [SystemNet]
    /// Pin key or splice key → net name.
    public let netOf: [String: String]
    public let bom: [SystemBOMLine]
    public let issues: [Issue]
    private let adjacency: [String: [(String, TraceStep.Via, String)]]

    public init(_ p: SystemProject) {
        var analyses: [EntityID: HarnessAnalysis] = [:]
        for i in p.harnesses { analyses[i.id] = HarnessAnalysis(i.harness) }

        // Connectivity graph: nodes are pin keys, splice keys ("H1/SP1") and lone unassigned ends.
        var adj: [String: [(String, TraceStep.Via, String)]] = [:]
        var nodes: Set<String> = []
        func link(_ a: String, _ b: String, _ via: TraceStep.Via, _ detail: String) {
            adj[a, default: []].append((b, via, detail))
            adj[b, default: []].append((a, via, detail))
            nodes.insert(a); nodes.insert(b)
        }
        var issues: [Issue] = []
        var wireSignals: [String: [String]] = [:]     // node → signals of wires touching it

        for inst in p.harnesses {
            let h = inst.harness
            for c in h.connectors {
                for cav in c.cavities { nodes.insert(SystemPin(.harness(inst.id, connector: c.id), cav.label).key) }
            }
            for w in h.wires {
                func key(_ e: Endpoint, _ side: String) -> String {
                    switch e {
                    case let .pin(c, cav): return SystemPin(.harness(inst.id, connector: c), cav).key
                    case let .splice(s): return "\(inst.id)/\(s)"
                    case .unassigned: return "\(inst.id)/\(w.id)·\(side)"
                    }
                }
                let a = key(w.from, "A"), b = key(w.to, "B")
                let len = analyses[inst.id]?.routes[w.id]?.lengthMM.map { String(format: "%.0f mm", $0) } ?? "no route"
                link(a, b, .wire(harness: inst.id, wire: w.id), "\(w.color) \(w.size), \(len)")
                if let s = w.signal, !s.isEmpty {
                    wireSignals[a, default: []].append(s)
                    wireSignals[b, default: []].append(s)
                }
            }
            for issue in analyses[inst.id]?.issues ?? [] where issue.severity != .info {
                issues.append(Issue(severity: issue.severity, subject: "\(inst.id)/\(issue.subject)", message: issue.message))
            }
        }
        var deviceSignal: [String: String] = [:]
        var devicePinKeys: Set<String> = []
        for d in p.devices {
            for c in d.connectors {
                for pin in c.pins {
                    let k = SystemPin(.device(d.id, connector: c.id), pin.label).key
                    nodes.insert(k)
                    devicePinKeys.insert(k)
                    if let s = pin.signal, !s.isEmpty { deviceSignal[k] = s }
                }
            }
        }

        // Mates
        var mateCount: [ConnectorRef: [EntityID]] = [:]
        for m in p.mates {
            mateCount[m.a, default: []].append(m.id)
            mateCount[m.b, default: []].append(m.id)
            guard let pa = p.pins(of: m.a) else { issues.append(Issue(severity: .error, subject: m.id, message: "\(m.a) does not exist.")); continue }
            guard let pb = p.pins(of: m.b) else { issues.append(Issue(severity: .error, subject: m.id, message: "\(m.b) does not exist.")); continue }
            if m.a.owner == m.b.owner && m.a.connector == m.b.connector {
                issues.append(Issue(severity: .error, subject: m.id, message: "A connector cannot mate with itself."))
                continue
            }
            if let ga = p.gender(of: m.a), let gb = p.gender(of: m.b), ga == gb {
                issues.append(Issue(severity: .warning, subject: m.id, message: "\(m.a) and \(m.b) are both \(ga.rawValue); mating halves need opposite genders."))
            }
            let bLabels = Set(pb.map(\.label))
            var unmatched: [String] = []
            for pin in pa {
                let partner = m.partner(ofA: pin.label)
                if bLabels.contains(partner) {
                    link(SystemPin(m.a, pin.label).key, SystemPin(m.b, partner).key, .mate(m.id), "\(p.displayName(of: m.a)) ⇄ \(p.displayName(of: m.b))")
                } else {
                    unmatched.append(pin.label)
                }
            }
            if !unmatched.isEmpty {
                issues.append(Issue(severity: .warning, subject: m.id,
                                    message: "Pin(s) \(unmatched.joined(separator: ", ")) of \(m.a) have no partner on \(m.b)."))
            }
            if pa.count != pb.count {
                issues.append(Issue(severity: .info, subject: m.id, message: "\(m.a) has \(pa.count) pins, \(m.b) has \(pb.count)."))
            }
        }
        for (ref, ids) in mateCount where ids.count > 1 {
            issues.append(Issue(severity: .error, subject: ref.description, message: "\(ref) is mated \(ids.count) times (\(ids.joined(separator: ", ")))."))
        }
        for ref in p.allConnectorRefs where mateCount[ref] == nil {
            issues.append(Issue(severity: .info, subject: ref.description, message: "\(p.displayName(of: ref)) is not mated."))
        }

        // Nets: connected components.
        var netOf: [String: String] = [:]
        var visited: Set<String> = []
        var groups: [[String]] = []
        for start in nodes.sorted(by: naturalLess) where !visited.contains(start) {
            var stack = [start], comp: [String] = []
            visited.insert(start)
            while let n = stack.popLast() {
                comp.append(n)
                for (m, _, _) in adj[n] ?? [] where !visited.contains(m) { visited.insert(m); stack.append(m) }
            }
            groups.append(comp)
        }
        var nets: [SystemNet] = []
        var unnamed = 0, usedNames: [String: Int] = [:]
        // Every connector pin, including loose terminals (ring lugs are net members even though they never mate).
        let pinKeys = devicePinKeys.union(p.harnesses.flatMap { i in
            i.harness.connectors.flatMap { c in c.cavities.map { SystemPin(.harness(i.id, connector: c.id), $0.label).key } }
        })
        for comp in groups {
            let pins = comp.filter { pinKeys.contains($0) }.sorted(by: naturalLess)
            var wires: [String] = []
            for n in comp {
                for (_, via, _) in adj[n] ?? [] {
                    if case let .wire(h, w) = via, !wires.contains("\(h)/\(w)") { wires.append("\(h)/\(w)") }
                }
            }
            let devPins = pins.filter(devicePinKeys.contains)
            let devSignals = Set(devPins.compactMap { deviceSignal[$0] })
            // Pins with no wire are only worth listing when a device gives them a signal (an open circuit).
            if wires.isEmpty && devSignals.isEmpty { continue }
            let wireSigs = comp.flatMap { wireSignals[$0] ?? [] }
            var name: String
            if let s = devSignals.sorted().first {
                name = s
            } else if let s = Dictionary(grouping: wireSigs, by: { $0 }).max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) })?.key {
                name = s
            } else {
                unnamed += 1
                name = "NET\(unnamed)"
            }
            usedNames[name, default: 0] += 1
            if usedNames[name]! > 1 { name += " (\(usedNames[name]!))" }
            if devSignals.count > 1 {
                let detail = devPins.compactMap { k in deviceSignal[k].map { "\(k) (\($0))" } }.joined(separator: ", ")
                issues.append(Issue(severity: .error, subject: name, message: "Short: one net joins different device signals: \(detail)."))
            }
            if let dev = devSignals.first, devSignals.count == 1 {
                let others = Set(wireSigs).subtracting([dev])
                if !others.isEmpty {
                    issues.append(Issue(severity: .warning, subject: name,
                                        message: "Device signal \(dev) is carried by wires named \(others.sorted().joined(separator: ", "))."))
                }
            }
            for n in comp { netOf[n] = name }
            nets.append(SystemNet(name: name, pins: pins, devicePins: devPins, wires: wires.sorted(by: naturalLess),
                                  harnesses: Array(Set(wires.compactMap { $0.split(separator: "/").first.map(String.init) })).sorted(by: naturalLess)))
        }
        // The same device signal on two separate nets usually means a missing wire.
        var netsBySignal: [String: [String]] = [:]
        for (k, s) in deviceSignal { if let n = netOf[k], !(netsBySignal[s]?.contains(n) ?? false) { netsBySignal[s, default: []].append(n) } }
        for (s, ns) in netsBySignal where ns.count > 1 {
            let where_ = deviceSignal.filter { $0.value == s }.keys.sorted(by: naturalLess).joined(separator: ", ")
            issues.append(Issue(severity: .warning, subject: s, message: "Open circuit? Device signal \(s) is split across \(ns.count) nets (\(where_))."))
        }
        for (k, s) in deviceSignal where netOf[k] == nil {
            issues.append(Issue(severity: .info, subject: k, message: "Device pin \(k) (\(s)) is not connected to any wire."))
        }

        self.harnessAnalyses = analyses
        self.adjacency = adj
        self.netOf = netOf
        self.nets = nets.sorted { naturalLess($0.name, $1.name) }
        self.bom = Self.buildBOM(p, analyses)
        self.issues = issues.sorted { ($0.severity.rank, $0.subject) < ($1.severity.rank, $1.subject) }
    }

    /// Breadth-first trace from a pin through wires, splices and mates.
    public func trace(from key: String) -> [TraceStep] {
        var steps: [TraceStep] = []
        var seen: Set<String> = [key]
        var queue: [(String, Int)] = [(key, 0)]
        while !queue.isEmpty {
            let (n, depth) = queue.removeFirst()
            for (m, via, detail) in (adjacency[n] ?? []).sorted(by: { naturalLess($0.0, $1.0) }) where !seen.contains(m) {
                seen.insert(m)
                steps.append(TraceStep(from: n, to: m, via: via, detail: detail, depth: depth + 1))
                queue.append((m, depth + 1))
            }
        }
        return steps
    }

    static func buildBOM(_ p: SystemProject, _ analyses: [EntityID: HarnessAnalysis]) -> [SystemBOMLine] {
        var lines: [String: SystemBOMLine] = [:]
        for inst in p.harnesses {
            for l in analyses[inst.id]?.bom ?? [] {
                let qty = l.quantity * Double(max(inst.quantity, 0))
                if lines[l.id] == nil {
                    var base = l
                    base.quantity = 0
                    base.references = []
                    base.computedQuantity = 0
                    base.isOverridden = false
                    lines[l.id] = SystemBOMLine(line: base, breakdown: [:])
                }
                lines[l.id]!.line.quantity += qty
                lines[l.id]!.line.references += l.references.map { "\(inst.id)/\($0)" }
                lines[l.id]!.breakdown[inst.id, default: 0] += qty
            }
        }
        for d in p.devices {
            for (part, ref) in [(d.part, d.id)] + d.connectors.map({ ($0.part, "\(d.id)/\($0.id)") }) {
                guard let part else { continue }
                let id = "Device|\(part.manufacturer)|\(part.mpn)"
                if lines[id] == nil {
                    lines[id] = SystemBOMLine(line: BOMLine(category: "Device", partKey: "\(part.manufacturer)|\(part.mpn)", mpn: part.mpn,
                                                            manufacturer: part.manufacturer, internalPN: part.internalPN ?? "",
                                                            description: part.description ?? d.name, quantity: 0, unit: .each,
                                                            references: [], unitPrice: part.unitPrice, alternates: part.alternates),
                                              breakdown: [:])
                }
                lines[id]!.line.quantity += 1
                lines[id]!.line.references.append(ref)
                lines[id]!.breakdown["Devices", default: 0] += 1
            }
        }
        let order = ["Device", "Connector", "Accessory", "Terminal", "Seal", "Cavity plug", "Wire", "Cable", "Splice", "Heat shrink", "Covering", "Clip", "Label"]
        return lines.values.sorted {
            let a = order.firstIndex(of: $0.line.category) ?? 99, b = order.firstIndex(of: $1.line.category) ?? 99
            return (a, $0.line.mpn, $0.line.description) < (b, $1.line.mpn, $1.line.description)
        }
    }
}
