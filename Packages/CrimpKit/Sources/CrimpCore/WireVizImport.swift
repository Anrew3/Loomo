import Foundation

/// Reads a WireViz YAML file (https://github.com/wireviz/WireViz) into a harness: connectors with their pin
/// counts, labels and part numbers, and one wire per connected cable core, with its gauge and color.
/// Splices and bundles aren't in WireViz files; Loomo adds a bundle between each pair of connectors it wires.
public enum WireVizImport {
    public struct Report: Sendable {
        public var connectors = 0
        public var splices = 0
        public var wires = 0
        public var skipped: [String] = []
    }

    public static func harness(fromYAML text: String, name: String = "Imported Harness") throws -> (Harness, Report) {
        guard case .map(let root) = try MiniYAML.parse(text) else { throw EditError.invalid("That isn't a WireViz file") }
        var h = Harness()
        h.name = name
        if case .map(let meta)? = root["metadata"], let title = meta["title"]?.string { h.name = title }
        var report = Report()

        // Connectors. Loomo's own exports write splices as one-pin connectors typed "Splice (…)": those become splices.
        var splices: Set<String> = []
        if case .map(let connectors)? = root["connectors"] {
            for (index, (id, value)) in connectors.entries.enumerated() {
                let c = value.mapValue
                if c["type"]?.string?.hasPrefix("Splice") == true {
                    let kind = c["type"]?.string.flatMap { t in SpliceKind.allCases.first { t.contains("(\($0.rawValue))") } } ?? .ultrasonic
                    _ = h.addSplice(id: id, kind: kind, at: Point2D(Double(index % 4) * 220 + 110, Double(index / 4) * 180 + 90))
                    splices.insert(id)
                    report.splices += 1
                    continue
                }
                let labels = c["pinlabels"]?.list.map { $0.compactMap(\.string) }
                let pins = c["pins"]?.list.map { $0.compactMap(\.string) }
                let simple = c["style"]?.string == "simple"
                let count = c["pincount"]?.string.flatMap(Int.init) ?? pins?.count ?? labels?.count ?? (simple ? 1 : nil)
                guard let count, count > 0 else {
                    report.skipped.append("\(id): no pin count")
                    continue
                }
                var spec = HarnessScript.ConnectorSpec(mpn: c["mpn"]?.string ?? "GENERIC",
                                                       manufacturer: c["manufacturer"]?.string,
                                                       description: c["type"]?.string ?? id, cavities: count)
                spec.id = id
                spec.name = c["type"]?.string
                spec.gender = c["subtype"]?.string.flatMap { Gender(rawValue: $0.lowercased()) }
                let (part, config) = HarnessScript.part(for: spec, library: nil)
                let at = Point2D(Double(index % 4) * 220, Double(index / 4) * 180)
                let placed = try HarnessScript.addConnector(spec, part: part, config: config, to: &h, at: at)
                if let i = h.connectors.firstIndex(where: { $0.id == placed }) {
                    // WireViz numbers pins 1…n unless it lists them; Loomo's cavity labels follow.
                    let names = pins ?? (1...count).map(String.init)
                    for (k, cavity) in h.connectors[i].cavities.indices.enumerated() where k < names.count {
                        h.connectors[i].cavities[cavity].label = names[k]
                        if let labels, k < labels.count, !labels[k].isEmpty { h.connectors[i].cavities[cavity].signal = labels[k] }
                    }
                }
                report.connectors += 1
            }
        }

        // Cables: gauge and per-core colors.
        struct Cable { var gauge: String?; var colors: [String]; var labels: [String] }
        var cables: [String: Cable] = [:]
        if case .map(let list)? = root["cables"] {
            for (id, value) in list.entries {
                let c = value.mapValue
                var colors = c["colors"]?.list?.compactMap(\.string) ?? []
                if colors.isEmpty, let code = c["color_code"]?.string, let n = c["wirecount"]?.string.flatMap(Int.init) {
                    colors = Array(colorCodes[code.uppercased()] ?? [], count: n)
                }
                cables[id] = Cable(gauge: c["gauge"]?.string, colors: colors, labels: c["wirelabels"]?.list?.compactMap(\.string) ?? [])
            }
        }

        // Connections: each set alternates connector, cable, connector… with matching lists of pins and cores.
        guard case .list(let sets)? = root["connections"] else { return (h, report) }
        for set in sets {
            guard case .list(let hops) = set else { continue }
            let steps: [(String, [String])] = hops.compactMap { hop in
                guard case .map(let m) = hop, let (id, v) = m.entries.first else {
                    if let id = hop.string { return (id, ["1"]) }
                    return nil
                }
                return (id, expand(v))
            }
            var i = 0
            while i + 2 < steps.count {
                let (a, aPins) = steps[i], (cable, cores) = steps[i + 1], (b, bPins) = steps[i + 2]
                guard let wireSpec = cables[cable] else {
                    // Connector to connector directly: move along.
                    i += 1
                    continue
                }
                for k in 0..<min(cores.count, max(aPins.count, bPins.count)) {
                    let pa = aPins.count == 1 ? aPins[0] : (k < aPins.count ? aPins[k] : nil)
                    let pb = bPins.count == 1 ? bPins[0] : (k < bPins.count ? bPins[k] : nil)
                    guard let pa, let pb else { continue }
                    let core = Int(cores[k]).map { $0 - 1 } ?? k
                    let color = core >= 0 && core < wireSpec.colors.count ? wireSpec.colors[core] : nil
                    let signal = core >= 0 && core < wireSpec.labels.count ? wireSpec.labels[core] : nil
                    do {
                        try HarnessScript.addWire(from: splices.contains(a) ? a : "\(a):\(pa)", to: splices.contains(b) ? b : "\(b):\(pb)", size: wireSpec.gauge.map(normalizedGauge),
                                                  color: color.map(normalizedColor), signal: signal, in: &h)
                        report.wires += 1
                    } catch {
                        report.skipped.append("\(a):\(pa) → \(b):\(pb) (\(cable) core \(core + 1)): \(error.localizedDescription)")
                    }
                }
                i += 2
            }
        }
        return (h, report)
    }

    /// "1-3" → 1, 2, 3; a list → its items; a single value → one item.
    static func expand(_ v: MiniYAML.Value) -> [String] {
        let items: [String] = v.list?.compactMap(\.string) ?? v.string.map { [$0] } ?? []
        return items.flatMap { item -> [String] in
            let parts = item.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]), lo <= hi, hi - lo < 300 {
                return (lo...hi).map(String.init)
            }
            return [item]
        }
    }

    /// WireViz writes "0.25 mm2", "0.5 mm²" or "20 AWG"; a bare number is mm².
    static func normalizedGauge(_ g: String) -> String {
        let t = g.trimmingCharacters(in: .whitespaces)
        return Double(t) != nil ? t + "mm2" : t
    }

    /// WireViz colors are IEC codes ("BK", "RDWH" for red with a white stripe).
    static func normalizedColor(_ c: String) -> String {
        let t = c.uppercased()
        if t.count == 4, !t.contains("/") { return String(t.prefix(2)) + "/" + String(t.suffix(2)) }
        return t
    }

    private static let colorCodes: [String: [String]] = [
        "DIN": ["WH", "BN", "GN", "YE", "GY", "PK", "BU", "RD", "BK", "VT"],
        "IEC": ["BN", "RD", "OG", "YE", "GN", "BU", "VT", "GY", "WH", "BK"],
        "BW": ["BK", "WH"],
    ]
}

private extension Array where Element == String {
    /// Repeats a color code list until it has `count` items.
    init(_ codes: [String], count: Int) {
        self = codes.isEmpty ? [] : (0..<count).map { codes[$0 % codes.count] }
    }
}

/// The YAML that WireViz files use: block maps and lists by indentation, flow lists `[a, b]`, flow maps
/// `{a: b}`, quoted and plain scalars, and comments. Not anchors, tags or multi-line strings.
public enum MiniYAML {
    public struct OrderedMap: Sendable {
        public var entries: [(String, Value)] = []
        public subscript(key: String) -> Value? { entries.first { $0.0 == key }?.1 }
    }

    public indirect enum Value: Sendable {
        case scalar(String), list([Value]), map(OrderedMap), null
        public var string: String? { if case .scalar(let s) = self { s } else { nil } }
        public var list: [Value]? { if case .list(let l) = self { l } else { nil } }
        var mapValue: OrderedMap { if case .map(let m) = self { m } else { OrderedMap() } }
    }

    private struct Line { var indent: Int; var text: String; var number: Int }

    public static func parse(_ text: String) throws -> Value {
        var lines: [Line] = []
        for (n, raw) in text.components(separatedBy: .newlines).enumerated() {
            let stripped = stripComment(raw)
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "---" { continue }
            let indent = stripped.prefix { $0 == " " }.count
            lines.append(Line(indent: indent, text: trimmed, number: n + 1))
        }
        var i = 0
        return try block(&lines, &i, indent: lines.first?.indent ?? 0)
    }

    private static func block(_ lines: inout [Line], _ i: inout Int, indent: Int) throws -> Value {
        guard i < lines.count else { return .null }
        if lines[i].text.hasPrefix("-") && (lines[i].text == "-" || lines[i].text.hasPrefix("- ")) {
            var items: [Value] = []
            while i < lines.count, lines[i].indent == indent, lines[i].text == "-" || lines[i].text.hasPrefix("- ") {
                let rest = String(lines[i].text.dropFirst()).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    i += 1
                    items.append(i < lines.count && lines[i].indent > indent ? try block(&lines, &i, indent: lines[i].indent) : .null)
                } else {
                    // "- key: value" opens a map whose further keys sit two columns in; "- value" is a scalar.
                    let inner = indent + 2
                    lines[i] = Line(indent: inner, text: rest, number: lines[i].number)
                    if splitKey(rest) != nil {
                        items.append(try block(&lines, &i, indent: inner))
                    } else {
                        items.append(try inline(rest))
                        i += 1
                    }
                }
            }
            return .list(items)
        }
        var map = OrderedMap()
        while i < lines.count, lines[i].indent == indent {
            let line = lines[i]
            guard let (key, rest) = splitKey(line.text) else {
                throw EditError.invalid("Line \(line.number): expected \"key: value\"")
            }
            i += 1
            if rest.isEmpty {
                if i < lines.count, lines[i].indent > indent || (lines[i].indent == indent && lines[i].text.hasPrefix("- ")) {
                    map.entries.append((key, try block(&lines, &i, indent: lines[i].indent)))
                } else {
                    map.entries.append((key, .null))
                }
            } else {
                map.entries.append((key, try inline(rest)))
            }
        }
        return .map(map)
    }

    /// "key: rest" outside quotes and brackets.
    private static func splitKey(_ s: String) -> (String, String)? {
        var depth = 0, quote: Character?
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if let q = quote { if ch == q { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "[" || ch == "{" { depth += 1 }
            else if ch == "]" || ch == "}" { depth -= 1 }
            else if ch == ":", depth == 0 {
                let next = s.index(after: idx)
                if next == s.endIndex || s[next] == " " {
                    let key = unquote(String(s[..<idx]).trimmingCharacters(in: .whitespaces))
                    return (key, String(s[next...]).trimmingCharacters(in: .whitespaces))
                }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private static func inline(_ s: String) throws -> Value {
        var chars = Array(s)
        var p = 0
        return try flow(&chars, &p, depth: 0)
    }

    private static func flow(_ c: inout [Character], _ p: inout Int, depth: Int) throws -> Value {
        while p < c.count, c[p] == " " { p += 1 }
        guard p < c.count else { return .null }
        if c[p] == "[" {
            p += 1
            var items: [Value] = []
            while p < c.count {
                while p < c.count, c[p] == " " || c[p] == "," { p += 1 }
                if p < c.count, c[p] == "]" { p += 1; break }
                items.append(try flow(&c, &p, depth: depth + 1))
            }
            return .list(items)
        }
        if c[p] == "{" {
            p += 1
            var map = OrderedMap()
            while p < c.count {
                while p < c.count, c[p] == " " || c[p] == "," { p += 1 }
                if p < c.count, c[p] == "}" { p += 1; break }
                let key = scalar(&c, &p, stops: ":,}")
                if p < c.count, c[p] == ":" { p += 1 }
                map.entries.append((key, try flow(&c, &p, depth: depth + 1)))
            }
            return .map(map)
        }
        // Inside brackets a plain scalar ends at , ] or }; on its own it runs to the end of the line.
        let s = scalar(&c, &p, stops: depth == 0 ? "" : ",]}")
        return s.isEmpty || s == "~" || s == "null" ? .null : .scalar(s)
    }

    private static func scalar(_ c: inout [Character], _ p: inout Int, stops: String) -> String {
        while p < c.count, c[p] == " " { p += 1 }
        if p < c.count, c[p] == "\"" || c[p] == "'" {
            let q = c[p]
            p += 1
            var out = ""
            while p < c.count, c[p] != q { out.append(c[p]); p += 1 }
            p += 1
            return out
        }
        var out = ""
        while p < c.count, !stops.contains(c[p]) { out.append(c[p]); p += 1 }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, let f = s.first, f == "\"" || f == "'", s.last == f { return String(s.dropFirst().dropLast()) }
        return s
    }

    private static func stripComment(_ s: String) -> String {
        var quote: Character?
        var prev: Character = " "
        for (i, ch) in s.enumerated() {
            if let q = quote { if ch == q { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "#", prev == " " || i == 0 { return String(s.prefix(i)) }
            prev = ch
        }
        return s
    }
}
