import Foundation

/// Every scripted harness edit, in one place: the `crimp` CLI, the MCP server (`crimp mcp`) and Loomo's live
/// bridge all run these, so a command means exactly the same thing whether it edits a file on disk or the
/// harness open in a window. The catalogue describes each command's parameters, and both the CLI help and the
/// MCP tool schemas are generated from it.
public enum HarnessCommands {
    // MARK: Options

    /// A command's arguments as text, the way the CLI receives them ("--length 6in", "--sealed").
    /// MCP arguments are converted to this form, so both front ends share one parser.
    public struct Options: Sendable {
        public var values: [String: String]
        public var flags: Set<String>
        public var positional: [String]

        public init(values: [String: String] = [:], flags: Set<String> = [], positional: [String] = []) {
            self.values = values
            self.flags = flags
            self.positional = positional
        }

        public subscript(_ key: String) -> String? { values[key] }
        public func has(_ flag: String) -> Bool { flags.contains(flag) }

        public func double(_ key: String) throws -> Double? {
            guard let v = values[key] else { return nil }
            guard let d = Double(v) else { throw EditError.invalid("\(key) must be a number, got \(v)") }
            return d
        }

        public func int(_ key: String) throws -> Int? {
            guard let v = values[key] else { return nil }
            guard let i = Int(v) else { throw EditError.invalid("\(key) must be a whole number, got \(v)") }
            return i
        }

        public func length(_ key: String) throws -> Double? {
            guard let v = values[key] else { return nil }
            do { return try HarnessScript.length(v) } catch { throw EditError.invalid("\(key): \(error.localizedDescription)") }
        }

        public func choice<T: RawRepresentable & CaseIterable>(_ key: String, _ type: T.Type) throws -> T? where T.RawValue == String {
            guard let v = values[key] else { return nil }
            guard let t = T.allCases.first(where: { $0.rawValue.lowercased() == v.lowercased() }) else {
                throw EditError.invalid("\(key) must be one of \(T.allCases.map(\.rawValue).joined(separator: ", ")), got \(v)")
            }
            return t
        }

        public func required(_ key: String, _ hint: String) throws -> String {
            guard let v = values[key], !v.isEmpty else { throw EditError.invalid("\(key) is required: \(hint)") }
            return v
        }

        /// Where a new item goes: the given x/y, or to the right of everything drawn so far.
        func point(in h: Harness) throws -> Point2D {
            if let x = try double("x"), let y = try double("y") { return Point2D(x, y) }
            return HarnessScript.defaultPoint(in: h)
        }
    }

    // MARK: Catalogue

    public struct Parameter: Sendable {
        public enum Kind: Sendable, Equatable {
            /// Free text. Lengths ("6in"), sizes ("18awg") and colours ("red/white") are text too.
            case text
            case number
            case integer
            /// A switch: present or absent ("--sealed").
            case flag
            /// "true" or "false" as a value.
            case boolean
            case choice([String])
            /// Several ids, comma-separated on the CLI.
            case list
        }

        public let name: String
        public let kind: Kind
        public let summary: String
        public let required: Bool

        public init(_ name: String, _ kind: Kind = .text, _ summary: String, required: Bool = false) {
            self.name = name
            self.kind = kind
            self.summary = summary
            self.required = required
        }
    }

    public struct Command: Sendable {
        public let name: String
        public let summary: String
        public let parameters: [Parameter]
        /// True when the command changes the harness (and so becomes one undo step in the app).
        public let edits: Bool
    }

    private static func choices<T: RawRepresentable & CaseIterable>(_ t: T.Type) -> Parameter.Kind where T.RawValue == String {
        .choice(T.allCases.map(\.rawValue))
    }

    private static let x = Parameter("x", .number, "Drawing x position (default: right of the existing drawing)")
    private static let y = Parameter("y", .number, "Drawing y position")

    public static let catalog: [Command] = [
        Command(name: "summary", summary: "A compact text description of the harness: connectors with used and free cavities, splices, bundles, wires with lengths, and the rule-check count. Read this first.", parameters: [], edits: false),
        Command(name: "info", summary: "Everything in the harness as structured data, with computed wire lengths, bundle diameters, the bill of materials and open issues.", parameters: [], edits: false),
        Command(name: "check", summary: "Run the rule check and list open errors and warnings.", parameters: [], edits: false),
        Command(name: "set", summary: "Change the harness name, revision, units or termination allowance.", parameters: [
            Parameter("name", .text, "Harness name"),
            Parameter("revision", .text, "Revision, e.g. B"),
            Parameter("units", choices(UnitSystem.self), "Display units"),
            Parameter("allowance", .text, "Length added at each termination, e.g. 20mm"),
        ], edits: true),
        Command(name: "add-connector", summary: "Place a connector (or terminal, ferrule, pigtail, device). Never invent part numbers or cavity counts.", parameters: [
            Parameter("mpn", .text, "Manufacturer part number, or GENERIC with a description for a placeholder", required: true),
            Parameter("manufacturer", .text, "Manufacturer"),
            Parameter("description", .text, "Description"),
            Parameter("cavities", .integer, "Cavity count; required unless the parts library knows the part"),
            Parameter("id", .text, "Designator to use, e.g. C7 (default: the next free one)"),
            Parameter("name", .text, "Name shown on the drawing, e.g. Headlamp LH"),
            Parameter("kind", choices(ConnectorKind.self), "What it is (default housing)"),
            Parameter("gender", choices(Gender.self), "Contact gender"),
            Parameter("sealed", .flag, "A sealed connector"),
            Parameter("no-library", .flag, "Ignore the parts library's configuration for this part"),
            x, y,
        ], edits: true),
        Command(name: "add-splice", summary: "Add a splice, on its own node or on an existing junction.", parameters: [
            Parameter("id", .text, "Designator, e.g. SP2"),
            Parameter("kind", choices(SpliceKind.self), "Splice type (default ultrasonic)"),
            Parameter("at", .text, "Put it on this node, connector or splice's node"),
            x, y,
        ], edits: true),
        Command(name: "add-node", summary: "Add a breakout point or a clip on the drawing.", parameters: [
            Parameter("kind", .choice(["breakout", "clip"]), "Node kind (default breakout)"),
            Parameter("label", .text, "Label"),
            x, y,
        ], edits: true),
        Command(name: "add-bundle", summary: "Join two nodes (or the nodes of connectors and splices) with a bundle segment.", parameters: [
            Parameter("from", .text, "C1, SP1 or N3", required: true),
            Parameter("to", .text, "C2, SP1 or N4", required: true),
            Parameter("length", .text, "Segment length, e.g. 6in (default: the drawn distance)"),
        ], edits: true),
        Command(name: "add-wire", summary: "Add a wire between two ends. Ends are C1:2 (connector C1, cavity 2) or SP1 (a splice). Bundles are added along the way unless no-bundle is set.", parameters: [
            Parameter("from", .text, "First end, e.g. C1:2 or SP1", required: true),
            Parameter("to", .text, "Second end", required: true),
            Parameter("id", .text, "Wire id, e.g. W12"),
            Parameter("size", .text, "e.g. 18awg or 0.5mm2 (default 20awg)"),
            Parameter("color", .text, "e.g. red, RD or red/white (default black)"),
            Parameter("signal", .text, "Signal name"),
            Parameter("insulation", .text, "Insulation type (default TXL)"),
            Parameter("double-crimp", .flag, "Allow a second wire in an occupied cavity"),
            Parameter("no-bundle", .flag, "Don't add a bundle segment when the ends aren't joined"),
        ], edits: true),
        Command(name: "set-part", summary: "Set a connector's part, or the terminal, seal or plug in some of its cavities.", parameters: [
            Parameter("connector", .text, "Connector, e.g. C1", required: true),
            Parameter("mpn", .text, "Part number", required: true),
            Parameter("manufacturer", .text, "Manufacturer"),
            Parameter("description", .text, "Description"),
            Parameter("cavity", .text, "Cavity 2, a list 1,3, used or unused; omit to set the housing"),
            Parameter("role", .choice(["terminal", "seal", "plug"]), "What goes in the cavity (default terminal)"),
            Parameter("min-wire", .number, "Terminal: smallest wire in mm²"),
            Parameter("max-wire", .number, "Terminal: largest wire in mm²"),
            Parameter("min-od", .text, "Seal: smallest insulation diameter, e.g. 1.2mm"),
            Parameter("max-od", .text, "Seal: largest insulation diameter"),
            Parameter("strip", .text, "Strip length, e.g. 4mm"),
            Parameter("crimp-tool", .text, "Crimp tool"),
            Parameter("no-library", .flag, "Ignore the parts library's copy of this part"),
        ], edits: true),
        Command(name: "set-cavity", summary: "Set a cavity's signal name or double-crimp flag.", parameters: [
            Parameter("connector", .text, "Connector, e.g. C1", required: true),
            Parameter("cavity", .text, "Cavity label, e.g. 2", required: true),
            Parameter("signal", .text, "Signal name; empty clears it"),
            Parameter("double-crimp", .boolean, "Two wires share this terminal"),
        ], edits: true),
        Command(name: "set-wire", summary: "Change a wire's signal, size, colour, insulation or length.", parameters: [
            Parameter("wire", .text, "Wire id, e.g. W2", required: true),
            Parameter("signal", .text, "Signal name; empty clears it"),
            Parameter("size", .text, "e.g. 18awg or 0.5mm2"),
            Parameter("color", .text, "e.g. red or RD/WH"),
            Parameter("insulation", .text, "Insulation type, e.g. TXL"),
            Parameter("extra", .text, "Extra length added to the route, e.g. 2in"),
            Parameter("length", .text, "Fixed length, e.g. 300mm, or auto to use the route"),
        ], edits: true),
        Command(name: "rename-connector", summary: "Rename a connector's designator (C3 to C9). Wires, mates and accepted checks follow.", parameters: [
            Parameter("connector", .text, "Current designator", required: true),
            Parameter("to", .text, "New designator", required: true),
        ], edits: true),
        Command(name: "rename-cavity", summary: "Rename a cavity (1 to A, 87a…). Wire ends and the face layout follow.", parameters: [
            Parameter("connector", .text, "Connector, e.g. C1", required: true),
            Parameter("cavity", .text, "Current label", required: true),
            Parameter("to", .text, "New label", required: true),
        ], edits: true),
        Command(name: "move", summary: "Move a connector, splice or node on the drawing. Bundle lengths stay as they are.", parameters: [
            Parameter("id", .text, "C1, SP1 or N3", required: true),
            Parameter("x", .number, "New x position", required: true),
            Parameter("y", .number, "New y position", required: true),
        ], edits: true),
        Command(name: "accept", summary: "Accept the open checks on a subject as a reviewed deviation, with a reason.", parameters: [
            Parameter("subject", .text, "What the check is about, e.g. C3:2", required: true),
            Parameter("reason", .text, "Why it's acceptable", required: true),
            Parameter("match", .text, "Only checks whose message contains this"),
            Parameter("by", .text, "Who accepted it"),
        ], edits: true),
        Command(name: "unaccept", summary: "Withdraw accepted deviations on a subject.", parameters: [
            Parameter("subject", .text, "e.g. C3:2", required: true),
            Parameter("match", .text, "Only those whose message contains this"),
        ], edits: true),
        Command(name: "add-fuse-box", summary: "Add a fuse holder; fuse Fk spans cavities 2k-1 and 2k.", parameters: [
            Parameter("fuses", .integer, "Number of fuses", required: true),
            Parameter("rating", .text, "e.g. 15 A"),
            x, y,
        ], edits: true),
        Command(name: "add-relay", summary: "Add an ISO relay socket (cavities 30, 85, 86, 87, 87a).", parameters: [
            Parameter("rating", .text, "e.g. 12 V 40 A"),
            x, y,
        ], edits: true),
        Command(name: "add-loose-pins", summary: "Add pins with no housing, to be pinned in later.", parameters: [
            Parameter("count", .integer, "Number of pins", required: true),
            x, y,
        ], edits: true),
        Command(name: "add-mated-pair", summary: "Add an in-line mated pair (female and male); each cavity passes through to its mate.", parameters: [
            Parameter("cavities", .integer, "Cavity count", required: true),
            x, y,
        ], edits: true),
        Command(name: "mate", summary: "Mate two connectors in line, or unmate one (b = none).", parameters: [
            Parameter("a", .text, "First connector", required: true),
            Parameter("b", .text, "Second connector, or none", required: true),
        ], edits: true),
        Command(name: "pass-through", summary: "Wire each cavity of one connector to the same cavity of another (a T-harness).", parameters: [
            Parameter("from", .text, "Source connector", required: true),
            Parameter("to", .text, "Destination connector", required: true),
            Parameter("size", .text, "Wire size (default 20awg)"),
            Parameter("color", .text, "Wire colour (default black)"),
            Parameter("insulation", .text, "Insulation (default TXL)"),
            Parameter("by-order", .flag, "Match cavities by position instead of label"),
            Parameter("include-used", .flag, "Also wire cavities that already have a wire"),
        ], edits: true),
        Command(name: "remove", summary: "Remove connectors, splices, wires, nodes, bundle segments, coverings or labels.", parameters: [
            Parameter("ids", .list, "What to remove, e.g. W3, C2", required: true),
        ], edits: true),
    ]

    public static func command(_ name: String) -> Command? { catalog.first { $0.name == name } }

    // MARK: Running

    /// Runs one command on `h`. Edit commands change `h` in place; the result is what to report back.
    /// Throws `EditError` for anything the user or model got wrong; `h` is then left untouched.
    public static func run(_ name: String, _ o: Options, on h: inout Harness, library: PartLibrary? = nil) throws -> [String: Any] {
        var copy = h
        let result = try apply(name, o, on: &copy, library: library)
        h = copy
        return result
    }

    private static func apply(_ name: String, _ o: Options, on h: inout Harness, library: PartLibrary?) throws -> [String: Any] {
        switch name {
        case "summary":
            return ["summary": HarnessScript.summary(of: h)]

        case "info":
            return HarnessReport.info(h)

        case "check":
            let a = HarnessAnalysis(h)
            let errors = a.issues.filter { $0.severity == .error }.count
            return ["errors": errors, "warnings": a.issues.filter { $0.severity == .warning }.count,
                    "accepted": a.issues.filter { $0.acceptedReason != nil }.count, "issues": HarnessReport.issues(a)]

        case "set":
            if let v = o["name"] { h.name = v }
            if let v = o["revision"] { h.revision = v }
            if let v = try o.choice("units", UnitSystem.self) { h.settings.units = v }
            if let v = try o.length("allowance") { h.settings.terminationAllowanceMM = v }
            return ["name": h.name, "revision": h.revision, "units": h.settings.units.rawValue,
                    "terminationAllowanceMM": h.settings.terminationAllowanceMM]

        case "add-connector":
            let mpn = try o.required("mpn", "use GENERIC with a description for a placeholder")
            var spec = HarnessScript.ConnectorSpec(mpn: mpn, manufacturer: o["manufacturer"], description: o["description"],
                                                   cavities: try o.int("cavities"))
            spec.kind = try o.choice("kind", ConnectorKind.self) ?? .housing
            spec.id = o["id"]
            spec.name = o["name"]
            spec.gender = try o.choice("gender", Gender.self)
            spec.sealed = o.has("sealed")
            let (part, config) = HarnessScript.part(for: spec, library: o.has("no-library") ? nil : library)
            let id = try HarnessScript.addConnector(spec, part: part, config: config, to: &h, at: try o.point(in: h))
            guard let c = h.connector(id) else { return ["created": id] }
            return ["created": id, "node": c.nodeID ?? NSNull(), "cavities": c.cavities.map(\.label),
                    "fromLibrary": config != nil, "photo": c.part?.imageURL?.absoluteString ?? NSNull()]

        case "add-splice":
            var at: EntityID?
            if let ref = o["at"] {
                guard let n = h.nodeID(for: ref) else { throw EditError.notFound(ref) }
                at = n
            }
            if let wanted = o["id"], h.splice(wanted) != nil || h.connector(wanted) != nil { throw EditError.invalid("\(wanted) is already used") }
            let id = h.addSplice(id: o["id"], kind: try o.choice("kind", SpliceKind.self) ?? .ultrasonic, at: try o.point(in: h), onNode: at)
            return ["created": id, "node": h.splice(id)?.nodeID ?? NSNull()]

        case "add-node":
            let kind = try o.choice("kind", NodeKind.self) ?? .breakout
            guard kind == .breakout || kind == .clip else { throw EditError.invalid("Use add-connector or add-splice for those") }
            return ["created": h.addNode(kind, at: try o.point(in: h), label: o["label"] ?? "")]

        case "add-bundle":
            let a = try o.required("from", "e.g. C1"), b = try o.required("to", "e.g. C2")
            let id = try h.addSegment(from: a, to: b, lengthMM: try o.length("length"))
            return ["created": id, "lengthMM": h.segment(id)?.lengthMM ?? 0]

        case "add-wire":
            let f = try o.required("from", "e.g. C1:2"), t = try o.required("to", "e.g. C2:1")
            let id = try HarnessScript.addWire(from: f, to: t, size: o["size"], color: o["color"], signal: o["signal"],
                                               insulation: o["insulation"], doubleCrimp: o.has("double-crimp"),
                                               addBundle: !o.has("no-bundle"), id: o["id"], in: &h)
            let w = h.wire(id)
            let route = HarnessAnalysis(h).routes[id]
            return ["created": id, "from": w?.from.description ?? f, "to": w?.to.description ?? t,
                    "lengthMM": route?.lengthMM.map { ($0 * 10).rounded() / 10 } ?? NSNull()]

        case "set-part":
            let cid = try o.required("connector", "e.g. C1")
            guard let i = h.connectors.firstIndex(where: { $0.id == cid }) else { throw EditError.notFound(cid) }
            let mpn = try o.required("mpn", "the part number")
            var part = PartRef(mpn: mpn, manufacturer: o["manufacturer"] ?? "", description: o["description"])
            if !o.has("no-library"), let lib = library?.entry(for: part) { part = lib.part }
            // Data the rule checker uses: wire range for terminals, insulation range for seals, tooling.
            if let v = try o.double("min-wire") { part.minWireMM2 = v }
            if let v = try o.double("max-wire") { part.maxWireMM2 = v }
            if let v = try o.length("min-od") { part.minInsulationODMM = v }
            if let v = try o.length("max-od") { part.maxInsulationODMM = v }
            if let v = try o.length("strip") { part.stripLengthMM = v }
            if let v = o["crimp-tool"] { part.crimpTool = v }
            if let spec = o["cavity"] {
                // One cavity, a list ("1,3"), "used" (every cavity with a wire) or "unused" (for plugs).
                let all = h.connectors[i].cavities.map(\.label)
                let labels: [String] = switch spec {
                case "used": all.filter { h.isOccupied(.pin(connector: cid, cavity: $0)) }
                case "unused": all.filter { !h.isOccupied(.pin(connector: cid, cavity: $0)) }
                default: spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                for label in labels {
                    guard let k = h.connectors[i].cavities.firstIndex(where: { $0.label == label }) else { throw EditError.notFound("\(cid):\(label)") }
                    switch o["role"] ?? "terminal" {
                    case "terminal": h.connectors[i].cavities[k].terminal = part
                    case "seal": h.connectors[i].cavities[k].seal = part
                    case "plug": h.connectors[i].cavities[k].plug = part
                    case let r: throw EditError.invalid("role must be terminal, seal or plug, got \(r)")
                    }
                }
                return ["updated": labels.map { "\(cid):\($0)" }, "role": o["role"] ?? "terminal", "part": HarnessReport.part(part)]
            }
            h.connectors[i].part = part
            return ["updated": cid, "part": HarnessReport.part(part)]

        case "set-cavity":
            let cid = try o.required("connector", "e.g. C1"), label = try o.required("cavity", "e.g. 2")
            guard let i = h.connectors.firstIndex(where: { $0.id == cid }),
                  let k = h.connectors[i].cavities.firstIndex(where: { $0.label == label }) else {
                throw EditError.notFound("\(cid):\(label)")
            }
            if let s = o["signal"] { h.connectors[i].cavities[k].signal = s.isEmpty ? nil : s }
            if let d = o["double-crimp"] { h.connectors[i].cavities[k].doubleCrimp = (d == "true") }
            return ["updated": "\(cid):\(label)"]

        case "set-wire":
            let wid = try o.required("wire", "e.g. W2")
            guard let i = h.wires.firstIndex(where: { $0.id == wid }) else { throw EditError.notFound(wid) }
            if let s = o["signal"] { h.wires[i].signal = s.isEmpty ? nil : s }
            if let s = o["size"] { h.wires[i].size = try HarnessScript.wireSize(s) }
            if let c = o["color"] { h.wires[i].color = try HarnessScript.wireColor(c) }
            if let ins = o["insulation"] { h.wires[i].insulation = ins }
            if o["size"] != nil || o["insulation"] != nil {
                h.wires[i].outerDiameterMM = WireTables.defaultOD(for: h.wires[i].size, insulation: h.wires[i].insulation)
            }
            if let e = try o.length("extra") { h.wires[i].extraLengthMM = e }
            if let l = o["length"] { h.wires[i].lengthOverrideMM = l == "auto" ? nil : try o.length("length") }
            return ["updated": wid, "lengthMM": HarnessAnalysis(h).routes[wid]?.lengthMM ?? NSNull()]

        case "rename-connector":
            let old = try o.required("connector", "e.g. C3"), new = try o.required("to", "e.g. C9")
            guard h.connector(old) != nil else { throw EditError.notFound(old) }
            guard h.renameConnector(old, to: new) else { throw EditError.invalid("\(new) is already used, or isn't a valid designator") }
            return ["renamed": old, "to": new]

        case "rename-cavity":
            let cid = try o.required("connector", "e.g. C1"), old = try o.required("cavity", "e.g. 1"), new = try o.required("to", "e.g. A")
            guard let c = h.connector(cid) else { throw EditError.notFound(cid) }
            guard c.cavities.contains(where: { $0.label == old }) else { throw EditError.notFound("\(cid):\(old)") }
            guard h.renameCavity(cid, old, to: new) else { throw EditError.invalid("\(cid) already has a cavity \(new)") }
            return ["renamed": "\(cid):\(old)", "to": "\(cid):\(new)"]

        case "move":
            let ref = try o.required("id", "C1, SP1 or N3")
            guard let n = h.nodeID(for: ref), let i = h.nodes.firstIndex(where: { $0.id == n }) else { throw EditError.notFound(ref) }
            guard let x = try o.double("x"), let y = try o.double("y") else { throw EditError.invalid("x and y are required") }
            h.nodes[i].position = Point2D(x, y)
            return ["moved": ref, "node": n, "x": x, "y": y]

        case "accept":
            let subject = try o.required("subject", "e.g. C3:2")
            let reason = try o.required("reason", "say why this is acceptable")
            let open = HarnessAnalysis(h).issues.filter { issue in
                issue.subject == subject && issue.severity != .info
                    && (o["match"].map { issue.message.localizedCaseInsensitiveContains($0) } ?? true)
            }
            guard !open.isEmpty else { throw EditError.invalid("No open error or warning on \(subject)\(o["match"].map { " matching “\($0)”" } ?? "")") }
            let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            for i in open where !h.acceptedIssues.contains(where: { $0.subject == i.subject && $0.message == i.message }) {
                h.acceptedIssues.append(AcceptedIssue(subject: i.subject, message: i.message, reason: reason, acceptedBy: o["by"], date: date))
            }
            return ["accepted": open.map { ["subject": $0.subject, "message": $0.message] }, "reason": reason]

        case "unaccept":
            let subject = try o.required("subject", "e.g. C3:2")
            let before = h.acceptedIssues.count
            h.acceptedIssues.removeAll { a in
                a.subject == subject && (o["match"].map { a.message.localizedCaseInsensitiveContains($0) } ?? true)
            }
            return ["removed": before - h.acceptedIssues.count]

        case "add-fuse-box":
            guard let n = try o.int("fuses"), n > 0 else { throw EditError.invalid("Give the number of fuses, e.g. 6") }
            let id = h.addFuseBox(at: try o.point(in: h), fuses: n, rating: o["rating"])
            return ["connector": id, "fuses": h.connector(id)?.boxItems.map { ["id": $0.id, "cavities": $0.cavities] } ?? []]

        case "add-relay":
            let id = h.addRelay(at: try o.point(in: h), rating: o["rating"])
            return ["connector": id, "cavities": h.connector(id)?.cavities.map(\.label) ?? []]

        case "add-loose-pins":
            guard let n = try o.int("count"), n > 0 else { throw EditError.invalid("Give the number of pins, e.g. 4") }
            return ["connector": h.addLoosePins(at: try o.point(in: h), count: n)]

        case "add-mated-pair":
            guard let n = try o.int("cavities"), n > 0 else { throw EditError.invalid("Give the cavity count, e.g. 12") }
            let (f, m) = h.addMatedPair(at: try o.point(in: h), cavities: n)
            return ["female": f, "male": m]

        case "mate":
            let a = try o.required("a", "e.g. C3"), b = try o.required("b", "e.g. C4, or none")
            guard h.connector(a) != nil else { throw EditError.notFound(a) }
            let other: EntityID? = b.lowercased() == "none" ? nil : b
            if let other, h.connector(other) == nil { throw EditError.notFound(other) }
            h.setMate(a, other)
            return ["a": a, "b": other ?? NSNull()]

        case "pass-through":
            let a = try o.required("from", "e.g. C1"), b = try o.required("to", "e.g. C2")
            let made = try h.passThrough(from: a, to: b, size: try HarnessScript.wireSize(o["size"] ?? "20awg"),
                                         color: try HarnessScript.wireColor(o["color"] ?? "BK"), insulation: o["insulation"] ?? "TXL",
                                         includeUsed: o.has("include-used"), matchByOrder: o.has("by-order"))
            return ["wires": made]

        case "remove":
            let ids = (o["ids"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []) + o.positional
            guard !ids.isEmpty else { throw EditError.invalid("Name what to remove, e.g. W3, C2") }
            for id in ids where h.connector(id) == nil && h.splice(id) == nil && h.wire(id) == nil && h.node(id) == nil
                && h.segment(id) == nil && !h.coverings.contains(where: { $0.id == id }) && !h.labels.contains(where: { $0.id == id }) {
                throw EditError.notFound(id)
            }
            h.delete(Set(ids))
            return ["removed": ids]

        default:
            throw EditError.invalid("Unknown command \(name)")
        }
    }

    /// Error and warning counts after an edit, added to every edit's result.
    public static func checkCounts(_ h: Harness) -> [String: Any] {
        let a = HarnessAnalysis(h)
        return ["errors": a.issues.filter { $0.severity == .error }.count,
                "warnings": a.issues.filter { $0.severity == .warning }.count]
    }
}

/// Harness contents as JSON-ready dictionaries (CLI output, MCP results).
public enum HarnessReport {
    public static func part(_ p: PartRef?) -> Any {
        guard let p else { return NSNull() }
        var d: [String: Any] = ["mpn": p.mpn, "manufacturer": p.manufacturer]
        if let v = p.description { d["description"] = v }
        if p.isGeneric { d["generic"] = true }
        return d
    }

    public static func issues(_ a: HarnessAnalysis) -> [[String: Any]] {
        a.issues.map { i -> [String: Any] in
            var d: [String: Any] = ["severity": i.severity.rawValue, "subject": i.subject, "message": i.message]
            if let r = i.acceptedReason { d["accepted"] = r }
            return d
        }
    }

    public static func info(_ h: Harness) -> [String: Any] {
        let a = HarnessAnalysis(h)
        let u = h.settings.units
        func len(_ mm: Double?) -> Any { mm.map { ["mm": ($0 * 10).rounded() / 10, "display": u.format($0)] as Any } ?? NSNull() }
        let wiresUsing = Dictionary(grouping: h.wires.flatMap { w in [w.from, w.to].map { ($0, w.id) } }, by: \.0)
        return [
            "name": h.name, "revision": h.revision, "units": u.rawValue,
            "terminationAllowanceMM": h.settings.terminationAllowanceMM,
            "connectors": h.connectors.map { c -> [String: Any] in
                [
                    "id": c.id, "name": c.name, "kind": c.kind.rawValue, "gender": c.gender.rawValue, "sealed": c.sealed,
                    "part": part(c.part), "node": c.nodeID ?? NSNull(),
                    "cavities": c.cavities.map { cav -> [String: Any] in
                        let end = Endpoint.pin(connector: c.id, cavity: cav.label)
                        return ["label": cav.label, "signal": cav.signal ?? NSNull(), "terminal": part(cav.terminal),
                                "seal": part(cav.seal), "plug": part(cav.plug), "doubleCrimp": cav.doubleCrimp ?? false,
                                "wires": (wiresUsing[end] ?? []).map(\.1)]
                    },
                ]
            },
            "splices": h.splices.map { s -> [String: Any] in
                ["id": s.id, "kind": s.kind.rawValue, "node": s.nodeID ?? NSNull(), "part": part(s.part),
                 "wires": (wiresUsing[.splice(s.id)] ?? []).map(\.1)]
            },
            "wires": h.wires.map { w -> [String: Any] in
                ["id": w.id, "from": w.from.description, "to": w.to.description, "size": w.size.description,
                 "color": w.color.description, "insulation": w.insulation, "signal": w.signal ?? NSNull(),
                 "length": len(a.routes[w.id]?.lengthMM)]
            },
            "nodes": h.nodes.map { ["id": $0.id, "kind": $0.kind.rawValue, "label": $0.label, "x": $0.position.x, "y": $0.position.y] },
            "bundles": h.segments.map { s -> [String: Any] in
                ["id": s.id, "from": s.nodeA, "to": s.nodeB, "length": len(s.lengthMM),
                 "diameterMM": ((a.bundleDiameterMM[s.id] ?? 0) * 10).rounded() / 10, "wires": a.segmentWires[s.id] ?? []]
            },
            "bom": a.bom.map { ["category": $0.category, "part": $0.partKey, "quantity": ($0.quantity * 10).rounded() / 10, "unit": $0.unit.rawValue] },
            "issues": issues(a),
        ]
    }
}
