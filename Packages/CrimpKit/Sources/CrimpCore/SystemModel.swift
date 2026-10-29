import Foundation

// MARK: - Devices

public struct DevicePin: Codable, Hashable, Sendable {
    public var label: String
    public var signal: String?

    public init(label: String, signal: String? = nil) {
        self.label = label
        self.signal = signal
    }
}

/// A connector on a device (ECU, sensor, battery…) that a harness connector mates with.
public struct DeviceConnector: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID          // e.g. "J1"
    public var name: String
    public var part: PartRef?
    public var gender: Gender
    public var pins: [DevicePin]

    public init(id: EntityID, name: String = "", part: PartRef? = nil, gender: Gender = .male, pinCount: Int) {
        self.id = id
        self.name = name
        self.part = part
        self.gender = gender
        self.pins = (1...max(1, pinCount)).map { DevicePin(label: String($0)) }
    }
}

public struct Device: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID          // e.g. "ECU"
    public var name: String
    public var part: PartRef?
    public var connectors: [DeviceConnector]
    public var position: Point2D
    public var notes: String

    public init(id: EntityID, name: String = "", part: PartRef? = nil, connectors: [DeviceConnector] = [],
                position: Point2D = Point2D(40, 40), notes: String = "") {
        self.id = id
        self.name = name
        self.part = part
        self.connectors = connectors
        self.position = position
        self.notes = notes
    }
}

// MARK: - Harness instances and mates

/// A harness used in the system. The design is stored inside the project; `quantity` multiplies it in the system BOM.
public struct HarnessInstance: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID          // e.g. "H1"
    public var harness: Harness
    public var quantity: Int
    public var position: Point2D

    public init(id: EntityID, harness: Harness, quantity: Int = 1, position: Point2D = Point2D(320, 40)) {
        self.id = id
        self.harness = harness
        self.quantity = quantity
        self.position = position
    }
}

/// A connector anywhere in the system: on a harness instance or on a device.
public enum ConnectorRef: Codable, Hashable, Sendable, CustomStringConvertible, Comparable {
    case harness(EntityID, connector: EntityID)
    case device(EntityID, connector: EntityID)

    public var owner: EntityID {
        switch self { case let .harness(h, _), let .device(h, _): h }
    }

    public var connector: EntityID {
        switch self { case let .harness(_, c), let .device(_, c): c }
    }

    public var description: String { "\(owner)/\(connector)" }

    public static func < (a: ConnectorRef, b: ConnectorRef) -> Bool { naturalLess(a.description, b.description) }
}

/// Two connectors plugged together. Pins mate by label unless `pinMap` says otherwise (A pin → B pin).
public struct Mate: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID          // e.g. "M1"
    public var a: ConnectorRef
    public var b: ConnectorRef
    public var pinMap: [String: String]

    public init(id: EntityID, a: ConnectorRef, b: ConnectorRef, pinMap: [String: String] = [:]) {
        self.id = id
        self.a = a
        self.b = b
        self.pinMap = pinMap
    }

    public func partner(ofA pin: String) -> String { pinMap[pin] ?? pin }

    public func involves(_ c: ConnectorRef) -> Bool { a == c || b == c }
}

// MARK: - Project

public struct SystemProject: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2
    public var schemaVersion = SystemProject.currentSchemaVersion
    public var name: String
    public var revision: String
    public var titleBlock: TitleBlock
    public var devices: [Device]
    public var harnesses: [HarnessInstance]
    public var mates: [Mate]
    public var notes: [DrawingNote]
    public var revisions: [Revision]

    public init(name: String = "Untitled System", revision: String = "A") {
        self.name = name
        self.revision = revision
        self.titleBlock = TitleBlock()
        self.devices = []
        self.harnesses = []
        self.mates = []
        self.notes = []
        self.revisions = []
    }

    public func device(_ id: EntityID) -> Device? { devices.first { $0.id == id } }
    public func instance(_ id: EntityID) -> HarnessInstance? { harnesses.first { $0.id == id } }

    /// Pins of any connector in the system, with the signal the owner gives each one.
    public func pins(of ref: ConnectorRef) -> [DevicePin]? {
        switch ref {
        case let .harness(h, c):
            return instance(h)?.harness.connector(c)?.cavities.map { DevicePin(label: $0.label, signal: $0.signal) }
        case let .device(d, c):
            return device(d)?.connectors.first { $0.id == c }?.pins
        }
    }

    public func gender(of ref: ConnectorRef) -> Gender? {
        switch ref {
        case let .harness(h, c): instance(h)?.harness.connector(c)?.gender
        case let .device(d, c): device(d)?.connectors.first { $0.id == c }?.gender
        }
    }

    public func part(of ref: ConnectorRef) -> PartRef? {
        switch ref {
        case let .harness(h, c): instance(h)?.harness.connector(c)?.part
        case let .device(d, c): device(d)?.connectors.first { $0.id == c }?.part
        }
    }

    public func displayName(of ref: ConnectorRef) -> String {
        let name: String? = switch ref {
        case let .harness(h, c): instance(h)?.harness.connector(c)?.name
        case let .device(d, c): device(d)?.connectors.first { $0.id == c }?.name
        }
        return [ref.description, name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Every connector that can take part in a mate. Loose terminals (rings, ferrules…) bolt to studs and are left out.
    public var allConnectorRefs: [ConnectorRef] {
        harnesses.flatMap { i in i.harness.connectors.filter { !$0.kind.isLooseTerminal }.map { ConnectorRef.harness(i.id, connector: $0.id) } }
            + devices.flatMap { d in d.connectors.map { ConnectorRef.device(d.id, connector: $0.id) } }
    }

    public func mate(for ref: ConnectorRef) -> Mate? { mates.first { $0.involves(ref) } }

    /// Next free id with the given prefix across devices, harness instances and mates.
    public func nextID(prefix: String) -> EntityID {
        let used = Set((devices.map(\.id) + harnesses.map(\.id) + mates.map(\.id)).compactMap { id -> Int? in
            guard id.hasPrefix(prefix) else { return nil }
            return Int(id.dropFirst(prefix.count))
        })
        var n = 1
        while used.contains(n) { n += 1 }
        return "\(prefix)\(n)"
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public extension SystemProject {
    func encoded() throws -> Data { try jsonData() }
    static func load(from data: Data) throws -> SystemProject { try JSONDecoder().decode(SystemProject.self, from: data) }

    /// Mates every unmated harness connector to the unmated device connector whose name or id matches its name.
    /// Returns the number of mates made.
    @discardableResult
    mutating func autoMateByName() -> Int {
        var made = 0
        for inst in harnesses {
            for c in inst.harness.connectors where !c.kind.isLooseTerminal && !c.name.isEmpty {
                let ref = ConnectorRef.harness(inst.id, connector: c.id)
                guard mate(for: ref) == nil else { continue }
                let key = c.name.lowercased()
                let target = devices.lazy.flatMap { d in d.connectors.map { (d, $0) } }.first { d, dc in
                    let candidates = [d.id, d.name, "\(d.id) \(dc.id)", "\(d.name) \(dc.id)", "\(d.id)/\(dc.id)", dc.name].map { $0.lowercased() }
                    return candidates.contains(key) && mate(for: .device(d.id, connector: dc.id)) == nil
                }
                if let (d, dc) = target {
                    mates.append(Mate(id: nextID(prefix: "M"), a: ref, b: .device(d.id, connector: dc.id)))
                    made += 1
                }
            }
        }
        return made
    }

    /// Creates a device connector shaped like a harness connector, with the mating gender and the same pin labels and signals.
    @discardableResult
    mutating func addMatingDeviceConnector(for ref: ConnectorRef, on deviceID: EntityID) -> ConnectorRef? {
        guard case let .harness(h, c) = ref, let con = instance(h)?.harness.connector(c),
              let di = devices.firstIndex(where: { $0.id == deviceID }) else { return nil }
        var n = 1
        while devices[di].connectors.contains(where: { $0.id == "J\(n)" }) { n += 1 }
        var dc = DeviceConnector(id: "J\(n)", name: con.name, gender: con.gender == .female ? .male : .female, pinCount: 1)
        dc.pins = con.cavities.map { DevicePin(label: $0.label, signal: $0.signal) }
        devices[di].connectors.append(dc)
        let newRef = ConnectorRef.device(deviceID, connector: dc.id)
        mates.append(Mate(id: nextID(prefix: "M"), a: ref, b: newRef))
        return newRef
    }

}

/// System connector references: `{"harness": "H1", "connector": "C1"}` or `{"device": "ECU", "connector": "J1"}`.
extension ConnectorRef {
    private enum Keys: String, CodingKey { case harness, device, connector }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let connector = try c.decode(EntityID.self, forKey: .connector)
        if let h = try c.decodeIfPresent(EntityID.self, forKey: .harness) {
            self = .harness(h, connector: connector)
        } else if let d = try c.decodeIfPresent(EntityID.self, forKey: .device) {
            self = .device(d, connector: connector)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "A connector reference needs \"harness\" or \"device\""))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .harness(h, connector): try c.encode(h, forKey: .harness); try c.encode(connector, forKey: .connector)
        case let .device(d, connector): try c.encode(d, forKey: .device); try c.encode(connector, forKey: .connector)
        }
    }
}
