import Foundation

/// A part in the team/private library, with its "design configuration": the parts that go with it.
public struct LibraryPart: Identifiable, Codable, Hashable, Sendable {
    public var id: String { part.manufacturer + "|" + part.mpn + (part.isGeneric ? "|" + (part.description ?? "") : "") }
    public var part: PartRef
    public var category: String          // matches PartsClient.PartCategory raw values
    /// Cavity count for housings, so applying the part sizes the connector.
    public var cavityCount: Int?
    public var sealed: Bool?
    public var related: [RelatedPart]
    public var notes: String
    /// Mating-face geometry shared by every connector using this part.
    public var faceLayout: FaceLayout?
    /// The user's own photo (a file in the library's Photos folder); beats the distributor photo everywhere.
    public var customPhotoURL: URL?
    /// When this entry last changed; team-library sync keeps the newest version of each part.
    public var modifiedAt: Date?
    /// The photo to show for this part.
    public var photoURL: URL? { customPhotoURL ?? part.imageURL }

    public init(part: PartRef, category: String, cavityCount: Int? = nil, sealed: Bool? = nil,
                related: [RelatedPart] = [], notes: String = "", faceLayout: FaceLayout? = nil) {
        self.faceLayout = faceLayout
        self.part = part
        self.category = category
        self.cavityCount = cavityCount
        self.sealed = sealed
        self.related = related
        self.notes = notes
    }
}

public struct RelatedPart: Codable, Hashable, Sendable {
    public enum Role: String, Codable, CaseIterable, Sendable {
        case terminal, seal, cavityPlug, wedgelock, backshell, boot, accessory, tool
    }
    public var role: Role
    public var part: PartRef
    /// For accessories: how many per connector.
    public var quantity: Int

    public init(role: Role, part: PartRef, quantity: Int = 1) {
        self.role = role
        self.part = part
        self.quantity = quantity
    }
}

public struct PartLibrary: Codable, Hashable, Sendable {
    public var parts: [LibraryPart] = []
    /// Parts removed from the library, by id, with when; lets team-library sync remove them elsewhere too.
    public var deleted: [String: Date]?
    public init(parts: [LibraryPart] = []) { self.parts = parts }

    /// The library entry for a part: exact MPN and manufacturer, or the same MPN (ignoring punctuation)
    /// from a manufacturer whose name shares a word ("TE Connectivity" vs "TE Connectivity / Deutsch").
    public func entry(for part: PartRef) -> LibraryPart? {
        if let exact = parts.first(where: { $0.part.isSamePart(as: part) }) { return exact }
        guard !part.isGeneric else { return nil }
        let mpn = Harness.normalizedMPN(part.mpn)
        let words = Self.words(part.manufacturer)
        return parts.first {
            !$0.part.isGeneric && Harness.normalizedMPN($0.part.mpn) == mpn
                && (words.isEmpty || !Self.words($0.part.manufacturer).isDisjoint(with: words))
        }
    }

    /// The photo to show for a part: the library's custom photo when there is one, else the part's own.
    public func photoURL(for part: PartRef) -> URL? {
        entry(for: part)?.customPhotoURL ?? part.imageURL
    }

    /// Where custom photos are kept, next to Library.json.
    public static var photosDirectory: URL {
        defaultURL.deletingLastPathComponent().appendingPathComponent("Photos", isDirectory: true)
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }

    /// Finds a part by MPN or any approved alternate.
    public func search(_ text: String) -> [LibraryPart] {
        let q = text.lowercased()
        guard !q.isEmpty else { return parts }
        return parts.filter { p in
            ([p.part.mpn, p.part.manufacturer, p.part.description ?? "", p.part.internalPN ?? "", p.category] + p.part.alternates)
                .contains { $0.lowercased().contains(q) }
        }
    }

    public mutating func upsert(_ p: LibraryPart) {
        if let i = parts.firstIndex(where: { $0.id == p.id }) { parts[i] = p } else { parts.append(p) }
    }

    /// Library housekeeping: entries that share an MPN, and entries that no design uses.
    public func duplicates() -> [[LibraryPart]] {
        Dictionary(grouping: parts) { $0.part.mpn.lowercased() }.values.filter { $0.count > 1 }.map { $0 }
    }

    public func unused(in designs: [Harness]) -> [LibraryPart] {
        let used = designs.flatMap { HarnessAnalysis.allParts($0).map(\.1) }
        return parts.filter { lp in !used.contains { $0.isSamePart(as: lp.part) } }
    }

    /// Parts used in a design that are not in the library.
    public func missing(from design: Harness) -> [PartRef] {
        var out: [PartRef] = []
        for (_, p) in HarnessAnalysis.allParts(design) where !p.isGeneric && entry(for: p) == nil {
            if !out.contains(where: { $0.isSamePart(as: p) }) { out.append(p) }
        }
        return out
    }

    // MARK: Storage

    /// ~/Library/Application Support/Loomo/Library.json, or the App Group container in the App Store build.
    public static var defaultURL: URL { SharedStorage.dataDirectory.appendingPathComponent("Library.json") }

    public static func load(from url: URL = defaultURL) -> PartLibrary {
        guard let data = try? Data(contentsOf: url), let lib = try? JSONDecoder().decode(PartLibrary.self, from: data) else {
            return .starter
        }
        return lib
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// A small starting library with one complete design configuration and generic parts.
    public static var starter: PartLibrary {
        let deutsch = "TE Connectivity / Deutsch"
        let socket = PartRef(mpn: "0462-201-16141", manufacturer: deutsch, description: "DT socket contact, size 16, 16–20 AWG",
                             stripLengthMM: 6, crimpTool: "HDT-48-00", minWireMM2: 0.5, maxWireMM2: 1.5)
        let pin = PartRef(mpn: "0460-202-16141", manufacturer: deutsch, description: "DT pin contact, size 16, 16–20 AWG",
                          stripLengthMM: 6, crimpTool: "HDT-48-00", minWireMM2: 0.5, maxWireMM2: 1.5)
        let plug = PartRef(mpn: "114017", manufacturer: deutsch, description: "DT sealing plug, size 16")
        func dt(_ mpn: String, ways: Int, female: Bool, lock: String) -> LibraryPart {
            LibraryPart(part: PartRef(mpn: mpn, manufacturer: deutsch, description: "DT \(female ? "plug" : "receptacle"), \(ways)-way"),
                        category: "connector", cavityCount: ways, sealed: false,
                        related: [RelatedPart(role: .terminal, part: female ? socket : pin),
                                  RelatedPart(role: .cavityPlug, part: plug),
                                  RelatedPart(role: .wedgelock, part: PartRef(mpn: lock, manufacturer: deutsch, description: "DT wedgelock, \(ways)-way"))])
        }
        return PartLibrary(parts: [
            dt("DT06-2S", ways: 2, female: true, lock: "W2S"),
            dt("DT06-4S", ways: 4, female: true, lock: "W4S"),
            dt("DT04-2P", ways: 2, female: false, lock: "W2P"),
            dt("DT04-4P", ways: 4, female: false, lock: "W4P"),
            LibraryPart(part: socket, category: "terminal"),
            LibraryPart(part: pin, category: "terminal"),
            LibraryPart(part: plug, category: "cavity_plug"),
            LibraryPart(part: .generic("Socket contact, 0.5–1.0 mm²"), category: "terminal"),
            LibraryPart(part: .generic("Wire seal, Ø1.2–1.7 mm"), category: "seal"),
            LibraryPart(part: .generic("M6 ring terminal, 0.5–1.5 mm²"), category: "terminal"),
            LibraryPart(part: .generic("Adhesive heat shrink, 3:1"), category: "heat_shrink"),
            LibraryPart(part: .generic("Split convoluted tube, 10 mm"), category: "covering"),
            LibraryPart(part: .generic("PET cloth tape, 19 mm"), category: "tape"),
        ])
    }
}

public extension Connector {
    /// Applies a housing's design configuration: cavity count, sealing, contacts, seals, plugs and accessories.
    mutating func apply(_ config: LibraryPart, usedCavities: Set<String>) {
        // Keep the richer, fresher part (distributor photo, rows, pitch…) and fill gaps from the library's copy.
        if var p = part, Harness.normalizedMPN(p.mpn) == Harness.normalizedMPN(config.part.mpn) {
            let lib = config.part
            p.internalPN = p.internalPN ?? lib.internalPN
            if p.alternates.isEmpty { p.alternates = lib.alternates }
            p.description = p.description ?? lib.description
            p.datasheetURL = p.datasheetURL ?? lib.datasheetURL
            p.imageURL = p.imageURL ?? lib.imageURL
            p.unitPrice = p.unitPrice ?? lib.unitPrice
            p.positionCount = p.positionCount ?? lib.positionCount
            p.rowCount = p.rowCount ?? lib.rowCount
            p.pitchMM = p.pitchMM ?? lib.pitchMM
            p.contactGender = p.contactGender ?? lib.contactGender
            part = p
        } else {
            part = config.part
        }
        if let n = config.cavityCount, n != cavities.count {
            if n > cavities.count {
                cavities += (cavities.count + 1...n).map { Cavity(label: String($0)) }
            } else {
                cavities.removeLast(cavities.count - n)
            }
        }
        if let s = config.sealed { sealed = s }
        // The contacts tell the housing's gender: pin contacts are male, socket contacts female.
        if let contact = config.related.first(where: { $0.role == .terminal })?.part.description?.lowercased() {
            if contact.contains("socket") { gender = .female } else if contact.contains("pin") { gender = .male }
        }
        for r in config.related {
            switch r.role {
            case .terminal:
                for i in cavities.indices where cavities[i].terminal == nil { cavities[i].terminal = r.part }
            case .seal:
                for i in cavities.indices where cavities[i].seal == nil { cavities[i].seal = r.part }
            case .cavityPlug:
                for i in cavities.indices where !usedCavities.contains(cavities[i].label) && cavities[i].plug == nil {
                    cavities[i].plug = r.part
                }
            case .wedgelock, .backshell, .boot, .accessory:
                if !accessories.contains(where: { $0.part.isSamePart(as: r.part) }) {
                    accessories.append(Accessory(kind: r.role.rawValue, part: r.part, quantity: r.quantity))
                }
            case .tool:
                break   // tools are listed through the terminals' crimpTool and the harness tool list
            }
        }
    }
}
