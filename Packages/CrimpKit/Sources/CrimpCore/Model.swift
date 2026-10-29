import Foundation

/// All lengths in the model are millimetres.
public typealias EntityID = String

// MARK: - Parts

/// A reference to a purchasable part, usually filled from an Octopart search or the team library.
public struct PartRef: Codable, Hashable, Sendable {
    public var mpn: String
    public var manufacturer: String
    public var description: String?
    public var octopartID: String?
    public var datasheetURL: URL?
    public var unitPrice: Double?
    /// Company part number printed on drawings and BOMs next to the MPN.
    public var internalPN: String?
    /// Approved alternate MPNs.
    public var alternates: [String]
    /// A placeholder ("16 AWG socket") to be replaced with an exact part before release.
    public var isGeneric: Bool
    // Terminal / seal / splice data used for lengths, tools and rule checks.
    public var stripLengthMM: Double?
    public var crimpTool: String?
    public var minWireMM2: Double?
    public var maxWireMM2: Double?
    public var minInsulationODMM: Double?
    public var maxInsulationODMM: Double?
    /// Product photo (Octopart's best image).
    public var imageURL: URL?
    /// Number of positions/cavities from the part's specs, used when placing a connector.
    public var positionCount: Int?
    /// "male" or "female" contact gender from the part's specs, when known.
    public var contactGender: String?
    /// Rows of cavities and cavity pitch from distributor data; used to draw the connector face.
    public var rowCount: Int?
    public var pitchMM: Double?
    /// Which parts source supplied each piece of data ("imageURL": "digikey", "datasheetURL": "mouser").
    public var dataSources: [String: String]?
    /// The distributor's product category ("Automotive Connectors", "Fuse Holders"); used to tell what a part is.
    public var category: String?

    public init(mpn: String, manufacturer: String, description: String? = nil,
                octopartID: String? = nil, datasheetURL: URL? = nil, unitPrice: Double? = nil,
                internalPN: String? = nil, alternates: [String] = [], isGeneric: Bool = false,
                stripLengthMM: Double? = nil, crimpTool: String? = nil,
                minWireMM2: Double? = nil, maxWireMM2: Double? = nil,
                minInsulationODMM: Double? = nil, maxInsulationODMM: Double? = nil) {
        self.mpn = mpn
        self.manufacturer = manufacturer
        self.description = description
        self.octopartID = octopartID
        self.datasheetURL = datasheetURL
        self.unitPrice = unitPrice
        self.internalPN = internalPN
        self.alternates = alternates
        self.isGeneric = isGeneric
        self.stripLengthMM = stripLengthMM
        self.crimpTool = crimpTool
        self.minWireMM2 = minWireMM2
        self.maxWireMM2 = maxWireMM2
        self.minInsulationODMM = minInsulationODMM
        self.maxInsulationODMM = maxInsulationODMM
    }

    public static func generic(_ description: String) -> PartRef {
        PartRef(mpn: "GENERIC", manufacturer: "—", description: description, isGeneric: true)
    }

    /// True when two references name the same purchasable part.
    public func isSamePart(as other: PartRef) -> Bool {
        mpn.caseInsensitiveCompare(other.mpn) == .orderedSame
            && manufacturer.caseInsensitiveCompare(other.manufacturer) == .orderedSame
            && (!isGeneric || description == other.description)
    }
}

// MARK: - Topology

public struct Point2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public enum NodeKind: String, Codable, CaseIterable, Sendable {
    case connector, splice, breakout, clip
}

public struct TopologyNode: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID
    public var kind: NodeKind
    public var label: String
    public var position: Point2D
    /// Clip, grommet or tie part for `.clip` nodes.
    public var part: PartRef?

    public init(id: EntityID, kind: NodeKind, label: String = "", position: Point2D, part: PartRef? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.position = position
        self.part = part
    }
}

/// A physical bundle section between two topology nodes.
public struct Segment: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID
    public var nodeA: EntityID
    public var nodeB: EntityID
    public var lengthMM: Double

    public init(id: EntityID, nodeA: EntityID, nodeB: EntityID, lengthMM: Double) {
        self.id = id
        self.nodeA = nodeA
        self.nodeB = nodeB
        self.lengthMM = lengthMM
    }
}

// MARK: - Connectors and terminations

public enum Gender: String, Codable, CaseIterable, Sendable { case male, female }

/// What sits at the end of the wires. Ring, spade, ferrule and quick-connect terminals are one-cavity "connectors".
public enum ConnectorKind: String, Codable, CaseIterable, Sendable {
    case housing, pigtail, device, ringTerminal, spadeTerminal, ferrule, quickConnect
    /// A fuse box or fuse holder: cavities take terminals, fuses plug in across pairs of cavities.
    case fuseBox
    /// A relay socket (ISO 30/85/86/87/87a) with the relay itself as an insert.
    case relay
    /// Terminated pins with no housing on this harness, to be pinned into a mating part later.
    case loosePins

    public var title: String {
        switch self {
        case .housing: "Connector housing"
        case .pigtail: "Pigtail connector"
        case .device: "Device (pin list)"
        case .ringTerminal: "Ring terminal"
        case .spadeTerminal: "Spade terminal"
        case .ferrule: "Ferrule"
        case .quickConnect: "Quick-connect"
        case .fuseBox: "Fuse box / holder"
        case .relay: "Relay socket"
        case .loosePins: "Loose pins (no housing)"
        }
    }

    /// Loose terminals carry their part on the single cavity, not on a housing.
    public var isLooseTerminal: Bool { [.ringTerminal, .spadeTerminal, .ferrule, .quickConnect].contains(self) }

    /// Fuse and relay boxes hold plug-in parts (fuses, relays) as well as terminals.
    public var isBox: Bool { self == .fuseBox || self == .relay }

    /// Kinds with a housing part bought for the harness (loose pins and device pin lists have none).
    public var hasHousing: Bool { !isLooseTerminal && self != .device && self != .loosePins }
}

/// What plugs into a fuse or relay box position.
public enum BoxItemKind: String, Codable, CaseIterable, Sendable {
    case fuse, relay, diode, jumper, circuitBreaker, other

    public var title: String {
        switch self {
        case .fuse: "Fuse"
        case .relay: "Relay"
        case .diode: "Diode"
        case .jumper: "Jumper"
        case .circuitBreaker: "Circuit breaker"
        case .other: "Other"
        }
    }

    /// Fuses, jumpers and breakers conduct between their cavities, so those cavities share a net.
    public var conducts: Bool { self == .fuse || self == .jumper || self == .circuitBreaker }
}

/// A fuse, relay or other part plugged into a box, spanning some of its cavities.
public struct BoxItem: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID          // "F1", "R1"
    public var kind: BoxItemKind
    public var part: PartRef?
    /// "15 A", "12 V 40 A".
    public var rating: String?
    /// Cavity labels it spans, e.g. ["1", "2"] for a fuse, ["30", "85", "86", "87"] for a relay.
    public var cavities: [String]

    public init(id: EntityID, kind: BoxItemKind, part: PartRef? = nil, rating: String? = nil, cavities: [String] = []) {
        self.id = id
        self.kind = kind
        self.part = part
        self.rating = rating
        self.cavities = cavities
    }
}

public struct Cavity: Codable, Hashable, Sendable {
    public var label: String
    public var signal: String?
    public var terminal: PartRef?
    public var seal: PartRef?
    /// Fitted instead of a wire in an unused cavity of a sealed connector.
    public var plug: PartRef?
    /// Two wires crimped into one terminal (a double crimp). Optional so older files still load.
    public var doubleCrimp: Bool?

    public init(label: String, signal: String? = nil, terminal: PartRef? = nil,
                seal: PartRef? = nil, plug: PartRef? = nil) {
        self.label = label
        self.signal = signal
        self.terminal = terminal
        self.seal = seal
        self.plug = plug
    }
}

public struct Accessory: Codable, Hashable, Sendable {
    public var kind: String   // "wedgelock", "backshell", "boot", "TPA" …
    public var part: PartRef
    public var quantity: Int

    public init(kind: String, part: PartRef, quantity: Int = 1) {
        self.kind = kind
        self.part = part
        self.quantity = quantity
    }
}

/// The kinds of connector accessory a drawing names; each is its own BOM type.
public enum AccessoryKinds {
    public static let all = ["TPA", "CPA", "Wire lock", "Lid", "Lid lock", "Backshell", "Boot", "Cover", "Wedgelock",
                             "Grommet", "Mounting clip", "Bracket", "Blind plug"]

    /// BOM category for an accessory's kind: one of `all` (matched loosely), else "Accessory".
    public static func category(_ kind: String) -> String {
        let k = kind.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: " ")
        return all.first { $0.lowercased() == k || $0.lowercased().replacingOccurrences(of: " ", with: "") == k.replacingOccurrences(of: " ", with: "") }
            ?? "Accessory"
    }
}

public struct Connector: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID          // reference designator, e.g. "C1"
    public var name: String
    public var kind: ConnectorKind
    public var part: PartRef?
    public var gender: Gender
    /// True when each used cavity needs its own wire seal and each unused one a plug
    /// (Superseal/MX150 style). Grommet-sealed housings such as Deutsch DT are false.
    public var sealed: Bool
    public var nodeID: EntityID?
    public var cavities: [Cavity]
    public var accessories: [Accessory]
    /// Columns in the pinout grid; nil picks a near-square layout.
    public var gridColumns: Int?
    /// Wire travelling inside the housing from the bundle end to the contact.
    public var insertionDepthMM: Double
    /// Extra wire inside a backshell or boot.
    public var backshellEntryMM: Double
    /// Pre-wired lead length on a pigtail connector; the harness wire is spliced to it.
    public var leadLengthMM: Double?
    public var notes: String
    /// Mating-face geometry for this connector only; nil uses the library's layout for its part, else an automatic one.
    public var faceLayout: FaceLayout?
    /// How far the photo and designator text have been moved from their default place by the connector dot.
    /// They always move together; a leader line joins them to the dot.
    public var tagOffset: Point2D?
    /// When true, dragging the photo/text moves only them; otherwise it moves the whole connector.
    public var tagUnlocked: Bool?
    /// Fuses, relays and other parts plugged into a fuse or relay box.
    public var boxItems: [BoxItem]
    /// The other half of an in-line mated pair in this harness. Cavities mate by label.
    public var mate: EntityID?
    /// This connector's own picture (for example a cropped OEM connector photo); wins over the part photo.
    public var imagePNG: Data?
    /// How far its connection table has been moved from its default place beside the connector.
    public var tableOffset: Point2D?

    public init(id: EntityID, name: String = "", kind: ConnectorKind = .housing, part: PartRef? = nil,
                gender: Gender = .female, sealed: Bool = false, nodeID: EntityID? = nil, cavityCount: Int,
                accessories: [Accessory] = [], insertionDepthMM: Double = 0, backshellEntryMM: Double = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.part = part
        self.gender = gender
        self.sealed = sealed
        self.nodeID = nodeID
        self.cavities = (1...max(1, cavityCount)).map { Cavity(label: String($0)) }
        self.accessories = accessories
        self.insertionDepthMM = insertionDepthMM
        self.backshellEntryMM = backshellEntryMM
        self.notes = ""
        self.boxItems = []
    }
}

// MARK: - Wires, cables and twists

public struct WireSize: Codable, Hashable, Sendable, CustomStringConvertible {
    public var crossSectionMM2: Double
    public var awg: Int?
    /// Free-text size for custom conductors, shown instead of the computed label.
    public var customLabel: String?

    public init(mm2: Double) { crossSectionMM2 = mm2; awg = nil }

    public static func awg(_ gauge: Int) -> WireSize {
        var size = WireSize(mm2: WireTables.awgToMM2[gauge] ?? 0.5)
        size.awg = gauge
        return size
    }

    public var description: String {
        if let customLabel, !customLabel.isEmpty { return customLabel }
        if let awg { return "\(awg) AWG" }
        return String(format: "%g mm²", crossSectionMM2)
    }
}

/// IEC 60757 colour codes, e.g. base "RD", stripe "WH" → "RD/WH".
public struct WireColor: Codable, Hashable, Sendable, CustomStringConvertible {
    public var base: String
    public var stripe: String?

    public init(_ base: String, stripe: String? = nil) {
        self.base = base
        self.stripe = stripe
    }

    public var description: String { stripe.map { "\(base)/\($0)" } ?? base }
}

public enum Endpoint: Codable, Hashable, Sendable, CustomStringConvertible {
    case pin(connector: EntityID, cavity: String)
    case splice(EntityID)
    /// A wire end waiting in the pinout editor's palette to be dropped into a cavity.
    case unassigned

    public var description: String {
        switch self {
        case let .pin(c, cav): return "\(c):\(cav)"
        case let .splice(s): return s
        case .unassigned: return "unassigned"
        }
    }

    public var connectorID: EntityID? {
        if case let .pin(c, _) = self { return c }
        return nil
    }
}

public enum WireRole: String, Codable, CaseIterable, Sendable { case conductor, drain, shield }

public struct Wire: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID
    public var signal: String?
    public var size: WireSize
    public var color: WireColor
    public var insulation: String              // TXL, GXL, SXL, PTFE …
    public var outerDiameterMM: Double
    public var part: PartRef?
    public var from: Endpoint
    public var to: Endpoint
    /// When set, replaces the length computed from the topology.
    public var lengthOverrideMM: Double?
    /// Added on top of the computed length (service loop, rework margin).
    public var extraLengthMM: Double
    /// Core of a multi-conductor cable; the cable's jacket is what counts in the bundle.
    public var cableID: EntityID?
    public var role: WireRole
    /// Text printed on the wire marker at each end; nil prints nothing.
    public var markerText: String?

    public init(id: EntityID, signal: String? = nil, size: WireSize, color: WireColor,
                insulation: String = "TXL", outerDiameterMM: Double? = nil, part: PartRef? = nil,
                from: Endpoint, to: Endpoint, lengthOverrideMM: Double? = nil, extraLengthMM: Double = 0,
                cableID: EntityID? = nil, role: WireRole = .conductor, markerText: String? = nil) {
        self.id = id
        self.signal = signal
        self.size = size
        self.color = color
        self.insulation = insulation
        self.outerDiameterMM = outerDiameterMM ?? WireTables.defaultOD(for: size, insulation: insulation)
        self.part = part
        self.from = from
        self.to = to
        self.lengthOverrideMM = lengthOverrideMM
        self.extraLengthMM = extraLengthMM
        self.cableID = cableID
        self.role = role
        self.markerText = markerText
    }
}

/// A multi-conductor cable. Its cores are `Wire`s whose `cableID` points here.
public struct Cable: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID
    public var name: String
    public var part: PartRef?
    public var shielded: Bool
    public var jacketODMM: Double
    /// Jacket stripped back at each end so the cores can fan out.
    public var jacketStripMM: Double
    public var colorHex: String

    public init(id: EntityID, name: String = "", part: PartRef? = nil, shielded: Bool = false,
                jacketODMM: Double = 5, jacketStripMM: Double = 40, colorHex: String = "#2B2B2B") {
        self.id = id
        self.name = name
        self.part = part
        self.shielded = shielded
        self.jacketODMM = jacketODMM
        self.jacketStripMM = jacketStripMM
        self.colorHex = colorHex
    }
}

/// Wires twisted together (twisted pair, triple …). Twisting makes each wire longer than the bundle.
public struct Twist: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID
    public var wireIDs: [EntityID]
    /// Length of one full twist.
    public var layLengthMM: Double

    public init(id: EntityID, wireIDs: [EntityID], layLengthMM: Double = 25) {
        self.id = id
        self.wireIDs = wireIDs
        self.layLengthMM = layLengthMM
    }
}

// MARK: - Splices

public enum SpliceKind: String, Codable, CaseIterable, Sendable {
    case ultrasonic, crimp, solderSleeve, inlineDiode, inlineResistor

    public var title: String {
        switch self {
        case .ultrasonic: "Ultrasonic weld"
        case .crimp: "Crimp splice"
        case .solderSleeve: "Solder sleeve"
        case .inlineDiode: "In-line diode"
        case .inlineResistor: "In-line resistor"
        }
    }
}

public struct Splice: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID
    public var kind: SpliceKind
    public var part: PartRef?
    public var heatShrink: PartRef?
    public var nodeID: EntityID?
    /// Component value for in-line parts, e.g. "1N4007" or "120 Ω".
    public var value: String?
    /// How far its connection table has been moved from its default place beside the splice.
    public var tableOffset: Point2D?

    public init(id: EntityID, kind: SpliceKind = .ultrasonic, part: PartRef? = nil,
                heatShrink: PartRef? = nil, nodeID: EntityID? = nil, value: String? = nil) {
        self.id = id
        self.kind = kind
        self.part = part
        self.heatShrink = heatShrink
        self.nodeID = nodeID
        self.value = value
    }
}

// MARK: - Coverings

public enum CoveringKind: String, Codable, CaseIterable, Sendable {
    case convolutedTube, braidedSleeve, heatShrink, sleeve, tape

    public var title: String {
        switch self {
        case .convolutedTube: "Convoluted tube"
        case .braidedSleeve: "Braided sleeve"
        case .heatShrink: "Heat shrink"
        case .sleeve: "PVC sleeve"
        case .tape: "Tape wrap"
        }
    }
}

public enum TapeStyle: String, Codable, CaseIterable, Sendable {
    case halfLap, spiral, spot
}

public struct TapeWrap: Codable, Hashable, Sendable {
    public var style: TapeStyle
    public var widthMM: Double
    /// Spiral pitch (spiral) or spacing between spots (spot). Ignored for half-lap.
    public var pitchMM: Double
    /// Turns per spot.
    public var turnsPerSpot: Int

    public init(style: TapeStyle = .halfLap, widthMM: Double = 19, pitchMM: Double = 50, turnsPerSpot: Int = 3) {
        self.style = style
        self.widthMM = widthMM
        self.pitchMM = pitchMM
        self.turnsPerSpot = turnsPerSpot
    }
}

public struct Covering: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID
    public var kind: CoveringKind
    public var part: PartRef?
    public var segmentIDs: [EntityID]
    /// Inner diameter for tube/sleeve/heat-shrink, checked against the bundle.
    public var innerDiameterMM: Double?
    /// For heat shrink and expandable braid: smallest diameter it can grip.
    public var minDiameterMM: Double?
    public var tape: TapeWrap?
    public var colorHex: String

    public init(id: EntityID, kind: CoveringKind, part: PartRef? = nil, segmentIDs: [EntityID],
                innerDiameterMM: Double? = nil, minDiameterMM: Double? = nil, tape: TapeWrap? = nil,
                colorHex: String = "#333333") {
        self.id = id
        self.kind = kind
        self.part = part
        self.segmentIDs = segmentIDs
        self.innerDiameterMM = innerDiameterMM
        self.minDiameterMM = minDiameterMM
        self.tape = kind == .tape ? (tape ?? TapeWrap()) : tape
        self.colorHex = colorHex
    }
}

// MARK: - Labels, notes, revisions, tools, annotations

public enum LabelPlacement: Codable, Hashable, Sendable {
    /// On a bundle segment, measured from the segment's node A.
    case segment(EntityID, offsetMM: Double)
    /// Next to a connector; the text follows the connector's designator unless overridden.
    case connector(EntityID)
}

public struct BundleLabel: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID
    public var placement: LabelPlacement
    /// Fixed text. When nil the text is synchronised from the item it is placed on.
    public var text: String?
    public var part: PartRef?

    public init(id: EntityID, placement: LabelPlacement, text: String? = nil, part: PartRef? = nil) {
        self.id = id
        self.placement = placement
        self.text = text
        self.part = part
    }
}

public struct DrawingNote: Identifiable, Codable, Hashable, Sendable {
    public var id: Int           // note number, drawn as a flag
    public var text: String
    /// Items flagged with this note on the drawing.
    public var attachedTo: [EntityID]

    public init(id: Int, text: String, attachedTo: [EntityID] = []) {
        self.id = id
        self.text = text
        self.attachedTo = attachedTo
    }
}

public struct Revision: Identifiable, Codable, Hashable, Sendable {
    public var id: String { rev + date }
    public var rev: String
    public var date: String
    public var description: String
    public var author: String

    public init(rev: String, date: String, description: String, author: String) {
        self.rev = rev
        self.date = date
        self.description = description
        self.author = author
    }
}

public enum ToolKind: String, Codable, CaseIterable, Sendable { case crimpTool, die, extractionTool, fixture, equipment }

public struct ToolItem: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID
    public var kind: ToolKind
    public var name: String
    public var partNumber: String
    public var notes: String

    public init(id: EntityID, kind: ToolKind, name: String, partNumber: String = "", notes: String = "") {
        self.id = id
        self.kind = kind
        self.name = name
        self.partNumber = partNumber
        self.notes = notes
    }
}

public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case text, arrow, rectangle, ellipse, image
    /// A titled frame drawn around part of the drawing (a sub-harness, an option or a variant).
    case frame
    /// A callout note on a yellow card, like a sticky note ("Stop tape 2 in from terminal").
    case sticky
}

/// Free drawing items for finishing the harness drawing.
public struct Annotation: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID
    public var kind: AnnotationKind
    /// Bounding box in canvas points. For arrows, origin → origin + size.
    public var x: Double, y: Double, width: Double, height: Double
    public var text: String
    public var colorHex: String
    public var imagePNG: Data?
    /// Draw order; higher is in front.
    public var z: Int
    /// Frames: a dashed outline, used for optional parts and variants.
    public var dashed: Bool?

    public init(id: EntityID, kind: AnnotationKind, x: Double, y: Double, width: Double = 120, height: Double = 40,
                text: String = "", colorHex: String = "#000000", imagePNG: Data? = nil, z: Int = 0) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.text = text
        self.colorHex = colorHex
        self.imagePNG = imagePNG
        self.z = z
    }
}

public enum SheetSize: String, Codable, CaseIterable, Sendable {
    case a4, a3, a2, a1, a0, letter, tabloid, archD
    /// Any size, from `TitleBlock.customWidthIn` × `customHeightIn`.
    case custom

    /// Landscape size in PostScript points.
    public var points: (width: Double, height: Double) {
        let mm: (Double, Double) = switch self {
        case .a4: (297, 210)
        case .a3: (420, 297)
        case .a2: (594, 420)
        case .a1: (841, 594)
        case .a0: (1189, 841)
        case .letter: (279.4, 215.9)
        case .tabloid: (431.8, 279.4)
        case .archD: (914.4, 609.6)
        case .custom: (431.8, 279.4)
        }
        return (mm.0 / 25.4 * 72, mm.1 / 25.4 * 72)
    }

    public var title: String {
        switch self {
        case .letter: "Letter"
        case .tabloid: "Tabloid (11×17)"
        case .archD: "ARCH D"
        case .custom: "Custom"
        default: rawValue.uppercased()
        }
    }
}

public struct TitleBlock: Codable, Hashable, Sendable {
    public var company: String = ""
    public var drawingNumber: String = ""
    public var drawnBy: String = ""
    public var checkedBy: String = ""
    public var approvedBy: String = ""
    public var sheetSize: SheetSize = .a3
    public var logoPNG: Data?
    /// Page size in inches when `sheetSize` is `.custom` (landscape: width ≥ height).
    public var customWidthIn: Double?
    public var customHeightIn: Double?
    public init() {}

    /// The page in PostScript points.
    public var pagePoints: (width: Double, height: Double) {
        if sheetSize == .custom, let w = customWidthIn, let h = customHeightIn, w > 1, h > 1 { return (w * 72, h * 72) }
        return sheetSize.points
    }
}

/// A rule-check result the engineer has reviewed and accepted (a deviation), with the reason.
/// It matches one exact check, so if the design changes and the message changes, the check comes back.
public struct AcceptedIssue: Codable, Hashable, Sendable {
    public var subject: EntityID
    public var message: String
    public var reason: String
    public var acceptedBy: String?
    public var date: String?

    public init(subject: EntityID, message: String, reason: String, acceptedBy: String? = nil, date: String? = nil) {
        self.subject = subject
        self.message = message
        self.reason = reason
        self.acceptedBy = acceptedBy
        self.date = date
    }
}

/// A manual BOM line (glue, cable ties, packaging) that the design doesn't model.
public struct ExtraBOMLine: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var part: PartRef
    public var quantity: Double
    public var category: String

    public init(id: String = UUID().uuidString, part: PartRef, quantity: Double = 1, category: String = "Other") {
        self.id = id
        self.part = part
        self.quantity = quantity
        self.category = category
    }
}

// MARK: - Harness

public enum UnitSystem: String, Codable, CaseIterable, Sendable {
    case metric, imperial

    public func format(_ mm: Double?, decimals: Int? = nil) -> String {
        guard let mm else { return "—" }
        switch self {
        case .metric: return String(format: "%.\(decimals ?? 0)f mm", mm)
        case .imperial:
            // Long lengths read the way shop drawings give them: 9 ft 5 in, 31 ft 7.75 in.
            let inches = (mm / 25.4 * 100).rounded() / 100
            if decimals == nil, abs(inches) < 12 { return "\(String(format: "%g", inches)) in" }
            guard decimals == nil else { return String(format: "%.\(decimals!)f in", mm / 25.4) }
            let feet = (abs(inches) / 12).rounded(.down)
            let rest = ((abs(inches) - feet * 12) * 100).rounded() / 100
            let sign = inches < 0 ? "-" : ""
            return rest == 0 ? "\(sign)\(Int(feet)) ft" : "\(sign)\(Int(feet)) ft \(String(format: "%g", rest)) in"
        }
    }

    /// Converts a value typed in this unit system to millimetres.
    public func toMM(_ v: Double) -> Double { self == .metric ? v : v * 25.4 }
    public func fromMM(_ mm: Double) -> Double { self == .metric ? mm : mm / 25.4 }
    public var symbol: String { self == .metric ? "mm" : "in" }
}

public struct HarnessSettings: Codable, Hashable, Sendable {
    /// Added at each wire end for stripping, crimping and the service loop.
    public var terminationAllowanceMM: Double = 20
    /// Covering and tape material margin.
    public var materialMarginPercent: Double = 5
    /// Bundle packing factor in D = k·√Σd².
    public var bundlePackingFactor: Double = 1.2
    /// Wire length rounding step for the cut list.
    public var cutLengthRoundingMM: Double = 5
    public var units: UnitSystem = .metric
    public var gridSize: Double = 10
    public var snapToGrid: Bool = true
    /// Draw part photos next to connectors (optional so older files still load).
    public var showPartPhotos: Bool?
    /// Draw each connector's and splice's connection table beside it on the drawing.
    public var showConnectionTables: Bool?
    /// Show BOM item numbers ("[3]") beside parts on the drawing.
    public var showItemNumbers: Bool?

    public init() {}
}

public struct Harness: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 3
    public var schemaVersion: Int = Harness.currentSchemaVersion
    public var name: String
    public var revision: String
    public var settings: HarnessSettings
    public var titleBlock: TitleBlock
    public var nodes: [TopologyNode]
    public var segments: [Segment]
    public var connectors: [Connector]
    public var wires: [Wire]
    public var cables: [Cable]
    public var twists: [Twist]
    public var splices: [Splice]
    public var coverings: [Covering]
    public var labels: [BundleLabel]
    public var notes: [DrawingNote]
    public var revisions: [Revision]
    public var tools: [ToolItem]
    public var annotations: [Annotation]
    /// BOM edits keyed by `BOMLine.id`: a fixed quantity, or exclusion.
    public var bomQuantityOverrides: [String: Double]
    public var bomExcluded: [String]
    public var bomExtraLines: [ExtraBOMLine]
    /// Reviewed rule-check results; they show as accepted instead of errors or warnings.
    public var acceptedIssues: [AcceptedIssue]

    public init(name: String = "Untitled Harness", revision: String = "A", settings: HarnessSettings = .init(),
                nodes: [TopologyNode] = [], segments: [Segment] = [], connectors: [Connector] = [],
                wires: [Wire] = [], splices: [Splice] = [], coverings: [Covering] = []) {
        self.name = name
        self.revision = revision
        self.settings = settings
        self.titleBlock = TitleBlock()
        self.nodes = nodes
        self.segments = segments
        self.connectors = connectors
        self.wires = wires
        self.cables = []
        self.twists = []
        self.splices = splices
        self.coverings = coverings
        self.labels = []
        self.notes = []
        self.revisions = []
        self.tools = []
        self.annotations = []
        self.bomQuantityOverrides = [:]
        self.bomExcluded = []
        self.bomExtraLines = []
        self.acceptedIssues = []
    }

    public func connector(_ id: EntityID) -> Connector? { connectors.first { $0.id == id } }
    public func splice(_ id: EntityID) -> Splice? { splices.first { $0.id == id } }
    public func node(_ id: EntityID) -> TopologyNode? { nodes.first { $0.id == id } }
    public func segment(_ id: EntityID) -> Segment? { segments.first { $0.id == id } }
    public func wire(_ id: EntityID) -> Wire? { wires.first { $0.id == id } }
    public func cable(_ id: EntityID) -> Cable? { cables.first { $0.id == id } }

    public func cavity(_ e: Endpoint) -> Cavity? {
        guard case let .pin(c, cav) = e else { return nil }
        return connector(c)?.cavities.first { $0.label == cav }
    }

    /// Next free id with the given prefix, e.g. "W" → "W7".
    public func nextID(prefix: String) -> EntityID {
        let all = nodes.map(\.id) + segments.map(\.id) + connectors.map(\.id) + wires.map(\.id)
            + splices.map(\.id) + coverings.map(\.id) + cables.map(\.id) + twists.map(\.id)
            + labels.map(\.id) + tools.map(\.id) + annotations.map(\.id)
        let used = Set(all.compactMap { id -> Int? in
            guard id.hasPrefix(prefix) else { return nil }
            // "C5F" and "C5M" (a mated pair) use number 5 too.
            return Int(id.dropFirst(prefix.count).prefix { $0.isNumber })
        })
        var n = 1
        while used.contains(n) { n += 1 }
        return "\(prefix)\(n)"
    }
}

// MARK: - Document I/O

public extension Harness {
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func load(from data: Data) throws -> Harness {
        try JSONDecoder().decode(Harness.self, from: data)
    }
}

// MARK: - File format
//
// Files are written in a tidy, stable shape and read leniently: any optional or defaulted field can be
// left out, so hand-written or generated files (CLI, MCP, scripts) only need what they mean.
// See Schemas/loomo.schema.json.

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

/// Wire ends: `{"pin": {"connector": "C1", "cavity": "2"}}`, `{"splice": "SP1"}` or `{"unassigned": true}`.
extension Endpoint {
    private enum Keys: String, CodingKey { case pin, splice, unassigned }
    private struct Pin: Codable { var connector: EntityID; var cavity: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let p = try c.decodeIfPresent(Pin.self, forKey: .pin) {
            self = .pin(connector: p.connector, cavity: p.cavity)
        } else if let s = try c.decodeIfPresent(String.self, forKey: .splice) {
            self = .splice(s)
        } else if c.contains(.unassigned) {
            self = .unassigned
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "A wire end needs \"pin\", \"splice\" or \"unassigned\""))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .pin(connector, cavity): try c.encode(Pin(connector: connector, cavity: cavity), forKey: .pin)
        case let .splice(id): try c.encode(id, forKey: .splice)
        case .unassigned: try c.encode(true, forKey: .unassigned)
        }
    }
}

/// Label positions: `{"segment": {"id": "S1", "offsetMM": 120}}` or `{"connector": "C1"}`.
extension LabelPlacement {
    private enum Keys: String, CodingKey { case segment, connector }
    private struct OnSegment: Codable { var id: EntityID; var offsetMM: Double }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let s = try c.decodeIfPresent(OnSegment.self, forKey: .segment) {
            self = .segment(s.id, offsetMM: s.offsetMM)
        } else if let id = try c.decodeIfPresent(String.self, forKey: .connector) {
            self = .connector(id)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "A label placement needs \"segment\" or \"connector\""))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .segment(id, offset): try c.encode(OnSegment(id: id, offsetMM: offset), forKey: .segment)
        case let .connector(id): try c.encode(id, forKey: .connector)
        }
    }
}

extension PartRef {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mpn: try c.value(.mpn, ""), manufacturer: try c.value(.manufacturer, ""),
                  description: try c.value(.description, nil), octopartID: try c.value(.octopartID, nil),
                  datasheetURL: try c.value(.datasheetURL, nil), unitPrice: try c.value(.unitPrice, nil),
                  internalPN: try c.value(.internalPN, nil), alternates: try c.value(.alternates, []),
                  isGeneric: try c.value(.isGeneric, false), stripLengthMM: try c.value(.stripLengthMM, nil),
                  crimpTool: try c.value(.crimpTool, nil), minWireMM2: try c.value(.minWireMM2, nil),
                  maxWireMM2: try c.value(.maxWireMM2, nil), minInsulationODMM: try c.value(.minInsulationODMM, nil),
                  maxInsulationODMM: try c.value(.maxInsulationODMM, nil))
        imageURL = try c.value(.imageURL, nil)
        positionCount = try c.value(.positionCount, nil)
        contactGender = try c.value(.contactGender, nil)
        rowCount = try c.value(.rowCount, nil)
        pitchMM = try c.value(.pitchMM, nil)
        dataSources = try c.value(.dataSources, nil)
        category = try c.value(.category, nil)
    }
}

extension TopologyNode {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(EntityID.self, forKey: .id), kind: try c.decode(NodeKind.self, forKey: .kind),
                  label: try c.value(.label, ""), position: try c.value(.position, Point2D(0, 0)),
                  part: try c.value(.part, nil))
    }
}

extension Cavity {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(label: try c.decode(String.self, forKey: .label), signal: try c.value(.signal, nil),
                  terminal: try c.value(.terminal, nil), seal: try c.value(.seal, nil), plug: try c.value(.plug, nil))
        doubleCrimp = try c.value(.doubleCrimp, nil)
    }
}

extension Connector {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(EntityID.self, forKey: .id), name: try c.value(.name, ""),
                  kind: try c.value(.kind, .housing), part: try c.value(.part, nil), gender: try c.value(.gender, .female),
                  sealed: try c.value(.sealed, false), nodeID: try c.value(.nodeID, nil), cavityCount: 1,
                  accessories: try c.value(.accessories, []), insertionDepthMM: try c.value(.insertionDepthMM, 0),
                  backshellEntryMM: try c.value(.backshellEntryMM, 0))
        cavities = try c.value(.cavities, [])
        gridColumns = try c.value(.gridColumns, nil)
        leadLengthMM = try c.value(.leadLengthMM, nil)
        notes = try c.value(.notes, "")
        faceLayout = try c.value(.faceLayout, nil)
        tagOffset = try c.value(.tagOffset, nil)
        tagUnlocked = try c.value(.tagUnlocked, nil)
        boxItems = try c.value(.boxItems, [])
        mate = try c.value(.mate, nil)
        imagePNG = try c.value(.imagePNG, nil)
        tableOffset = try c.value(.tableOffset, nil)
    }
}

extension WireSize {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let awg = try c.decodeIfPresent(Int.self, forKey: .awg)
        if let mm2 = try c.decodeIfPresent(Double.self, forKey: .crossSectionMM2) {
            self.init(mm2: mm2)
            self.awg = awg
        } else if let awg {
            self = .awg(awg)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "A wire size needs \"awg\" or \"crossSectionMM2\""))
        }
        customLabel = try c.value(.customLabel, nil)
    }
}

extension Wire {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let size = try c.decode(WireSize.self, forKey: .size)
        let insulation = try c.value(.insulation, "TXL")
        self.init(id: try c.decode(EntityID.self, forKey: .id), signal: try c.value(.signal, nil), size: size,
                  color: try c.value(.color, WireColor("BK")), insulation: insulation,
                  outerDiameterMM: try c.value(.outerDiameterMM, nil), part: try c.value(.part, nil),
                  from: try c.value(.from, .unassigned), to: try c.value(.to, .unassigned),
                  lengthOverrideMM: try c.value(.lengthOverrideMM, nil), extraLengthMM: try c.value(.extraLengthMM, 0),
                  cableID: try c.value(.cableID, nil), role: try c.value(.role, .conductor),
                  markerText: try c.value(.markerText, nil))
    }
}

extension Cable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(EntityID.self, forKey: .id), name: try c.value(.name, ""), part: try c.value(.part, nil),
                  shielded: try c.value(.shielded, false), jacketODMM: try c.value(.jacketODMM, 5),
                  jacketStripMM: try c.value(.jacketStripMM, 40), colorHex: try c.value(.colorHex, "#2B2B2B"))
    }
}

extension Twist {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(EntityID.self, forKey: .id), wireIDs: try c.value(.wireIDs, []),
                  layLengthMM: try c.value(.layLengthMM, 25))
    }
}

extension BoxItem {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(EntityID.self, forKey: .id), kind: try c.value(.kind, .fuse), part: try c.value(.part, nil),
                  rating: try c.value(.rating, nil), cavities: try c.value(.cavities, []))
    }
}

extension Splice {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(EntityID.self, forKey: .id), kind: try c.value(.kind, .ultrasonic),
                  part: try c.value(.part, nil), heatShrink: try c.value(.heatShrink, nil),
                  nodeID: try c.value(.nodeID, nil), value: try c.value(.value, nil))
        tableOffset = try c.value(.tableOffset, nil)
    }
}

extension Covering {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(EntityID.self, forKey: .id), kind: try c.decode(CoveringKind.self, forKey: .kind),
                  part: try c.value(.part, nil), segmentIDs: try c.value(.segmentIDs, []),
                  innerDiameterMM: try c.value(.innerDiameterMM, nil), minDiameterMM: try c.value(.minDiameterMM, nil),
                  tape: try c.value(.tape, nil), colorHex: try c.value(.colorHex, "#333333"))
    }
}

extension HarnessSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        terminationAllowanceMM = try c.value(.terminationAllowanceMM, terminationAllowanceMM)
        materialMarginPercent = try c.value(.materialMarginPercent, materialMarginPercent)
        bundlePackingFactor = try c.value(.bundlePackingFactor, bundlePackingFactor)
        cutLengthRoundingMM = try c.value(.cutLengthRoundingMM, cutLengthRoundingMM)
        units = try c.value(.units, units)
        gridSize = try c.value(.gridSize, gridSize)
        snapToGrid = try c.value(.snapToGrid, snapToGrid)
        showPartPhotos = try c.value(.showPartPhotos, nil)
        showConnectionTables = try c.value(.showConnectionTables, nil)
        showItemNumbers = try c.value(.showItemNumbers, nil)
    }
}

extension TitleBlock {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        company = try c.value(.company, "")
        drawingNumber = try c.value(.drawingNumber, "")
        drawnBy = try c.value(.drawnBy, "")
        checkedBy = try c.value(.checkedBy, "")
        approvedBy = try c.value(.approvedBy, "")
        sheetSize = try c.value(.sheetSize, .a3)
        logoPNG = try c.value(.logoPNG, nil)
        customWidthIn = try c.value(.customWidthIn, nil)
        customHeightIn = try c.value(.customHeightIn, nil)
    }
}

extension Harness {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.value(.name, "Untitled Harness"), revision: try c.value(.revision, "A"),
                  settings: try c.value(.settings, HarnessSettings()), nodes: try c.value(.nodes, []),
                  segments: try c.value(.segments, []), connectors: try c.value(.connectors, []),
                  wires: try c.value(.wires, []), splices: try c.value(.splices, []), coverings: try c.value(.coverings, []))
        schemaVersion = try c.value(.schemaVersion, Harness.currentSchemaVersion)
        titleBlock = try c.value(.titleBlock, TitleBlock())
        cables = try c.value(.cables, [])
        twists = try c.value(.twists, [])
        labels = try c.value(.labels, [])
        notes = try c.value(.notes, [])
        revisions = try c.value(.revisions, [])
        tools = try c.value(.tools, [])
        annotations = try c.value(.annotations, [])
        bomQuantityOverrides = try c.value(.bomQuantityOverrides, [:])
        bomExcluded = try c.value(.bomExcluded, [])
        bomExtraLines = try c.value(.bomExtraLines, [])
        acceptedIssues = try c.value(.acceptedIssues, [])
    }
}
