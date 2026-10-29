import Foundation

// MARK: - Layout model

/// Physical arrangement of a connector's mating face, in millimetres with the origin at the face centre
/// (x to the right, y down) as seen looking into the mating face.
public struct FaceLayout: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable { case rectangle, rounded, circle }

    public struct FaceCavity: Codable, Hashable, Sendable {
        public var label: String
        public var x: Double
        public var y: Double
        public var diameter: Double

        public init(label: String, x: Double, y: Double, diameter: Double) {
            self.label = label
            self.x = x
            self.y = y
            self.diameter = diameter
        }
    }

    /// A keying rib, latch or polarisation feature drawn as a filled rectangle.
    public struct Key: Codable, Hashable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    public var shape: Shape
    public var width: Double
    public var height: Double
    public var cavities: [FaceCavity]
    public var keys: [Key]
    /// Datasheet or photo traced to make this layout (PNG/JPEG), with its scale and offset.
    public var backdropPNG: Data?
    public var backdropMMPerPixel: Double?
    public var backdropOffset: Point2D?
    /// Where the layout came from, e.g. "Preset: 2 rows" or "Traced from datasheet".
    public var source: String

    public init(shape: Shape = .rounded, width: Double, height: Double, cavities: [FaceCavity], keys: [Key] = [],
                source: String = "") {
        self.shape = shape
        self.width = width
        self.height = height
        self.cavities = cavities
        self.keys = keys
        self.source = source
    }

    public func cavity(_ label: String) -> FaceCavity? { cavities.first { $0.label == label } }
}

// MARK: - Presets (generic geometry, not manufacturer data)

public extension FaceLayout {
    enum Preset: String, CaseIterable, Codable, Sendable {
        case singleRow, twoRows, grid, staggered, circular

        public var title: String {
            switch self {
            case .singleRow: "Single row"
            case .twoRows: "Two rows"
            case .grid: "Grid"
            case .staggered: "Staggered rows"
            case .circular: "Circular"
            }
        }
    }

    /// Generates a face for `labels` cavities. `pitch` is cavity centre spacing; `cavityDiameter` the drawn cavity size.
    static func preset(_ preset: Preset, labels: [String], columns: Int? = nil, pitch: Double = 5,
                       cavityDiameter: Double = 3.2) -> FaceLayout {
        let n = max(labels.count, 1)
        var pts: [(Double, Double)] = []
        var shape: Shape = .rounded
        switch preset {
        case .singleRow:
            pts = (0..<n).map { (Double($0) * pitch, 0) }
        case .twoRows:
            let cols = Int((Double(n) / 2).rounded(.up))
            pts = (0..<n).map { i in (Double(i % cols) * pitch, Double(i / cols) * pitch) }
        case .grid:
            let cols = columns ?? max(1, Int(Double(n).squareRoot().rounded(.up)))
            pts = (0..<n).map { i in (Double(i % cols) * pitch, Double(i / cols) * pitch) }
        case .staggered:
            let cols = columns ?? max(1, Int((Double(n) / 2).rounded(.up)))
            pts = (0..<n).map { i in
                let row = i / cols
                return (Double(i % cols) * pitch + (row % 2 == 1 ? pitch / 2 : 0), Double(row) * pitch * 0.87)
            }
        case .circular:
            shape = .circle
            if n == 1 {
                pts = [(0, 0)]
            } else {
                let r = max(pitch * Double(n) / (2 * .pi), pitch * 0.75)
                pts = (0..<n).map { i in
                    let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
                    return (r * cos(a), r * sin(a))
                }
            }
        }
        // Centre the points on the origin and size the housing around them.
        let xs = pts.map(\.0), ys = pts.map(\.1)
        let cx = (xs.min()! + xs.max()!) / 2, cy = (ys.min()! + ys.max()!) / 2
        let cavities = zip(labels.isEmpty ? ["1"] : labels, pts).map {
            FaceCavity(label: $0.0, x: $0.1.0 - cx, y: $0.1.1 - cy, diameter: cavityDiameter)
        }
        let margin = cavityDiameter + 2.5
        var w = (xs.max()! - xs.min()!) + 2 * margin
        var h = (ys.max()! - ys.min()!) + 2 * margin
        if shape == .circle { w = max(w, h); h = w }
        // A latch/key bar on top so orientation is unambiguous.
        let key = Key(x: -w * 0.2, y: -h / 2 - 1.6, width: w * 0.4, height: 1.6)
        return FaceLayout(shape: shape, width: w, height: h, cavities: cavities, keys: [key], source: "Preset: \(preset.title)")
    }

    /// A sensible default for a connector with no layout yet.
    static func automatic(for c: Connector) -> FaceLayout {
        let labels = c.cavities.map(\.label)
        // Distributor data (rows, pitch) beats guessing from the count.
        if let rows = c.part?.rowCount, rows >= 1 {
            let pitch = c.part?.pitchMM ?? 5
            let diameter = pitch * 0.62
            var l: FaceLayout
            switch rows {
            case 1: l = preset(.singleRow, labels: labels, pitch: pitch, cavityDiameter: diameter)
            case 2: l = preset(.twoRows, labels: labels, pitch: pitch, cavityDiameter: diameter)
            default: l = preset(.grid, labels: labels, columns: Int((Double(labels.count) / Double(rows)).rounded(.up)), pitch: pitch, cavityDiameter: diameter)
            }
            l.source = "From distributor data: \(rows) row\(rows == 1 ? "" : "s")\(c.part?.pitchMM.map { String(format: ", %g mm pitch", $0) } ?? "")"
            return l
        }
        if let cols = c.gridColumns { return preset(.grid, labels: labels, columns: cols) }
        switch labels.count {
        case 0...3: return preset(.singleRow, labels: labels)
        case let n where n.isMultiple(of: 2) && n <= 24: return preset(.twoRows, labels: labels)
        default: return preset(.grid, labels: labels)
        }
    }

    /// Mirror left-to-right, for drawing the wire (rear) side.
    func mirrored() -> FaceLayout {
        var m = self
        m.cavities = cavities.map { FaceCavity(label: $0.label, x: -$0.x, y: $0.y, diameter: $0.diameter) }
        m.keys = keys.map { Key(x: -$0.x - $0.width, y: $0.y, width: $0.width, height: $0.height) }
        return m
    }
}

// MARK: - Drawing primitives

/// A resolution-independent drawing of a connector face. Renderers (SVG, CoreGraphics) only translate these.
public struct FaceDrawing: Sendable {
    public enum Primitive: Sendable, Hashable {
        case rect(x: Double, y: Double, w: Double, h: Double, radius: Double, fill: String?, stroke: String?, lineWidth: Double)
        case circle(cx: Double, cy: Double, r: Double, fill: String?, stroke: String?, lineWidth: Double)
        /// A stripe band across a circle (clipped to it) for two-colour wires.
        case stripe(cx: Double, cy: Double, r: Double, color: String)
        case hatch(cx: Double, cy: Double, r: Double, color: String)
        /// Right half of a disc in another colour: two wires crimped into one terminal.
        case rightHalf(cx: Double, cy: Double, r: Double, color: String)
        case text(x: Double, y: Double, string: String, size: Double, color: String, bold: Bool, anchor: Anchor)
        /// A traced picture of the real face (PNG/JPEG), drawn in place of the plain housing outline.
        case image(data: Data, x: Double, y: Double, w: Double, h: Double, mirrored: Bool)
    }

    public enum Anchor: String, Sendable { case start, middle, end }

    public var width: Double
    public var height: Double
    public var primitives: [Primitive]
    /// Cavity centres and radii in drawing units, for hit-testing.
    public var cavityHits: [String: (x: Double, y: Double, r: Double)]
}

public struct FaceDrawingOptions: Sendable {
    public var scale: Double = 12            // drawing units (points) per mm
    public var wireSide = false
    public var showLegend = true
    public var title: String?
    public var selectedCavity: String?
    public var ink = "#1A1A1A"
    public var secondary = "#6B6B6B"
    public var housing = "#E7E9EC"
    public var accent = "#0A84FF"
    public init() {}
}

public extension Harness {
    /// The layout used for a connector: its own, else the library's for its part, else an automatic one.
    func faceLayout(for c: Connector, library: PartLibrary? = nil) -> FaceLayout {
        if let own = c.faceLayout { return own }
        if let part = c.part, let lib = library?.entry(for: part)?.faceLayout {
            // Library layouts may name cavities differently; keep the library geometry, matched by order.
            if Set(lib.cavities.map(\.label)) == Set(c.cavities.map(\.label)) { return lib }
            if lib.cavities.count == c.cavities.count {
                var l = lib
                for i in l.cavities.indices { l.cavities[i].label = c.cavities[i].label }
                return l
            }
        }
        return .automatic(for: c)
    }

    /// Builds the face drawing of a connector with each cavity coloured by its wire.
    func faceDrawing(for c: Connector, layout: FaceLayout, options o: FaceDrawingOptions = FaceDrawingOptions()) -> FaceDrawing {
        let layout = o.wireSide ? layout.mirrored() : layout
        let s = o.scale
        let pad = 24.0
        let titleH = o.title == nil ? 0.0 : 22
        let faceW = layout.width * s, faceH = layout.height * s
        let keyTop = layout.keys.map { $0.y * s }.min().map { min(0, $0 + faceH / 2) } ?? 0
        let ox = pad + faceW / 2, oy = pad + titleH - keyTop + faceH / 2
        var prims: [FaceDrawing.Primitive] = []
        var hits: [String: (x: Double, y: Double, r: Double)] = [:]

        if let title = o.title {
            prims.append(.text(x: pad, y: pad - 6, string: title, size: 13, color: o.ink, bold: true, anchor: .start))
        }
        prims.append(.text(x: ox + faceW / 2, y: pad + titleH - 6, string: o.wireSide ? "WIRE SIDE" : "MATING FACE",
                           size: 9, color: o.secondary, bold: true, anchor: .end))
        // Housing: the traced picture of the real face when there is one, else a plain outline with its keys.
        if let png = layout.backdropPNG {
            prims.append(.image(data: png, x: ox - faceW / 2, y: oy - faceH / 2, w: faceW, h: faceH, mirrored: o.wireSide))
        } else {
        switch layout.shape {
        case .circle:
            prims.append(.circle(cx: ox, cy: oy, r: min(faceW, faceH) / 2, fill: o.housing, stroke: o.ink, lineWidth: 1.5))
        case .rectangle, .rounded:
            prims.append(.rect(x: ox - faceW / 2, y: oy - faceH / 2, w: faceW, h: faceH,
                               radius: layout.shape == .rounded ? min(faceW, faceH) * 0.12 : 0, fill: o.housing, stroke: o.ink, lineWidth: 1.5))
        }
        for k in layout.keys {
            prims.append(.rect(x: ox + k.x * s, y: oy + k.y * s, w: k.width * s, h: k.height * s, radius: 1.5,
                               fill: o.ink, stroke: nil, lineWidth: 0))
        }
        }

        // Cavities
        var legend: [(label: String, wires: [Wire], cavity: Cavity)] = []
        for fc in layout.cavities {
            guard let cav = c.cavities.first(where: { $0.label == fc.label }) else { continue }
            let here = Endpoint.pin(connector: c.id, cavity: fc.label)
            let cavityWires = wires.filter { $0.from == here || $0.to == here }
            let wire = cavityWires.first
            let cx = ox + fc.x * s, cy = oy + fc.y * s, r = fc.diameter * s / 2
            hits[fc.label] = (cx, cy, r)
            let selected = o.selectedCavity == fc.label
            if let wire {
                let base = WireTables.iecColors[wire.color.base] ?? "#999999"
                prims.append(.circle(cx: cx, cy: cy, r: r, fill: base, stroke: o.ink, lineWidth: selected ? 3 : 1))
                if let stripe = wire.color.stripe {
                    prims.append(.stripe(cx: cx, cy: cy, r: r, color: WireTables.iecColors[stripe] ?? "#999999"))
                    prims.append(.circle(cx: cx, cy: cy, r: r, fill: nil, stroke: o.ink, lineWidth: selected ? 3 : 1))
                }
                if cavityWires.count > 1 {
                    prims.append(.rightHalf(cx: cx, cy: cy, r: r, color: WireTables.iecColors[cavityWires[1].color.base] ?? "#999999"))
                    prims.append(.circle(cx: cx, cy: cy, r: r, fill: nil, stroke: o.ink, lineWidth: selected ? 3 : 1))
                }
            } else if cav.plug != nil {
                prims.append(.circle(cx: cx, cy: cy, r: r, fill: "#9A9A9A", stroke: o.ink, lineWidth: selected ? 3 : 1))
                prims.append(.hatch(cx: cx, cy: cy, r: r, color: "#5A5A5A"))
            } else {
                prims.append(.circle(cx: cx, cy: cy, r: r, fill: "#FFFFFF", stroke: o.ink, lineWidth: selected ? 3 : 1))
            }
            if selected {
                prims.append(.circle(cx: cx, cy: cy, r: r + 3, fill: nil, stroke: o.accent, lineWidth: 2))
            }
            // Cavity number just above-left of the cavity, readable on any wire colour.
            prims.append(.text(x: cx - r - 1, y: cy - r - 2, string: fc.label, size: max(7, min(11, r * 0.9)),
                               color: o.ink, bold: true, anchor: .end))
            legend.append((fc.label, cavityWires, cav))
        }

        var height = oy + faceH / 2 + pad
        var width = ox + faceW / 2 + pad
        if o.showLegend {
            // Legend: one row per cavity — swatch, cavity, wire, signal, size/colour, other end — in fixed columns.
            let lx = width + 4
            let cols: [Double] = [14, 44, 84, 186, 270]
            var ly = pad + titleH + 4
            for (i, head) in ["CAV", "WIRE", "SIGNAL", "SIZE", "TO"].enumerated() {
                prims.append(.text(x: lx + cols[i], y: ly, string: head, size: 8, color: o.secondary, bold: true, anchor: .start))
            }
            ly += 14
            for row in legend.sorted(by: { naturalLess($0.label, $1.label) }) {
                let here = Endpoint.pin(connector: c.id, cavity: row.label)
                for w in row.wires {
                    prims.append(.circle(cx: lx + 5, cy: ly - 3, r: 5, fill: WireTables.iecColors[w.color.base] ?? "#999999", stroke: o.ink, lineWidth: 0.75))
                    if let st = w.color.stripe {
                        prims.append(.stripe(cx: lx + 5, cy: ly - 3, r: 5, color: WireTables.iecColors[st] ?? "#999999"))
                        prims.append(.circle(cx: lx + 5, cy: ly - 3, r: 5, fill: nil, stroke: o.ink, lineWidth: 0.75))
                    }
                    let other = w.from == here ? w.to : w.from
                    let cells = [row.label, w.id, String((w.signal ?? "").prefix(18)), "\(w.size) \(w.color)", other.description]
                    for (i, text) in cells.enumerated() {
                        prims.append(.text(x: lx + cols[i], y: ly, string: text, size: 8.5, color: o.ink, bold: i == 0, anchor: .start))
                    }
                    ly += 14
                }
                if row.wires.isEmpty {
                    let plugged = row.cavity.plug != nil
                    prims.append(.circle(cx: lx + 5, cy: ly - 3, r: 5, fill: plugged ? "#9A9A9A" : "#FFFFFF", stroke: o.ink, lineWidth: 0.75))
                    prims.append(.text(x: lx + cols[0], y: ly, string: row.label, size: 8.5, color: o.secondary, bold: true, anchor: .start))
                    prims.append(.text(x: lx + cols[1], y: ly, string: plugged ? "plugged" : "empty", size: 8.5, color: o.secondary, bold: false, anchor: .start))
                    ly += 14
                }
            }
            width = lx + 340
            height = max(height, ly + pad)
        }
        return FaceDrawing(width: width, height: height, primitives: prims, cavityHits: hits)
    }
}

public extension FaceDrawing {
    /// Cavity under a point (drawing units).
    func cavity(at x: Double, _ y: Double) -> String? {
        cavityHits.first { hypot($0.value.x - x, $0.value.y - y) <= $0.value.r + 3 }?.key
    }

    /// Standalone SVG document.
    func svg() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func f(_ v: Double) -> String { String(format: "%.2f", v) }
        func paint(_ fill: String?, _ stroke: String?, _ lw: Double) -> String {
            "fill=\"\(fill ?? "none")\" stroke=\"\(stroke ?? "none")\" stroke-width=\"\(f(lw))\""
        }
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(f(width)) \(f(height))\" width=\"\(f(width))\" height=\"\(f(height))\" font-family=\"Helvetica, Arial, sans-serif\">\n"
        out += "<rect width=\"100%\" height=\"100%\" fill=\"#FFFFFF\"/>\n"
        var clip = 0
        for p in primitives {
            switch p {
            case let .rect(x, y, w, h, r, fill, stroke, lw):
                out += "<rect x=\"\(f(x))\" y=\"\(f(y))\" width=\"\(f(w))\" height=\"\(f(h))\" rx=\"\(f(r))\" \(paint(fill, stroke, lw))/>\n"
            case let .circle(cx, cy, r, fill, stroke, lw):
                out += "<circle cx=\"\(f(cx))\" cy=\"\(f(cy))\" r=\"\(f(r))\" \(paint(fill, stroke, lw))/>\n"
            case let .stripe(cx, cy, r, color):
                clip += 1
                out += "<clipPath id=\"c\(clip)\"><circle cx=\"\(f(cx))\" cy=\"\(f(cy))\" r=\"\(f(r))\"/></clipPath>"
                out += "<rect x=\"\(f(cx - r))\" y=\"\(f(cy - r * 0.28))\" width=\"\(f(2 * r))\" height=\"\(f(r * 0.56))\" fill=\"\(color)\" clip-path=\"url(#c\(clip))\" transform=\"rotate(-35 \(f(cx)) \(f(cy)))\"/>\n"
            case let .hatch(cx, cy, r, color):
                clip += 1
                out += "<clipPath id=\"c\(clip)\"><circle cx=\"\(f(cx))\" cy=\"\(f(cy))\" r=\"\(f(r))\"/></clipPath><g clip-path=\"url(#c\(clip))\" stroke=\"\(color)\" stroke-width=\"1\">"
                var d = -2 * r
                while d <= 2 * r {
                    out += "<line x1=\"\(f(cx + d - r))\" y1=\"\(f(cy + r))\" x2=\"\(f(cx + d + r))\" y2=\"\(f(cy - r))\"/>"
                    d += max(r / 2.5, 2)
                }
                out += "</g>\n"
            case let .image(data, x, y, w, h, mirrored):
                let type = data.starts(with: [0xFF, 0xD8]) ? "jpeg" : "png"
                let flip = mirrored ? " transform=\"translate(\(f(2 * x + w)) 0) scale(-1 1)\"" : ""
                out += "<image x=\"\(f(x))\" y=\"\(f(y))\" width=\"\(f(w))\" height=\"\(f(h))\" preserveAspectRatio=\"none\"\(flip) href=\"data:image/\(type);base64,\(data.base64EncodedString())\"/>\n"
            case let .rightHalf(cx, cy, r, color):
                out += "<path d=\"M \(f(cx)) \(f(cy - r)) A \(f(r)) \(f(r)) 0 0 1 \(f(cx)) \(f(cy + r)) Z\" fill=\"\(color)\"/>\n"
            case let .text(x, y, string, size, color, bold, anchor):
                let ws = string.contains("  ") ? " xml:space=\"preserve\" font-family=\"Menlo, monospace\"" : ""
                out += "<text x=\"\(f(x))\" y=\"\(f(y))\" font-size=\"\(f(size))\" fill=\"\(color)\" text-anchor=\"\(anchor.rawValue)\"\(bold ? " font-weight=\"bold\"" : "")\(ws)>\(esc(string))</text>\n"
            }
        }
        return out + "</svg>\n"
    }
}

extension FaceLayout {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(shape: try c.decodeIfPresent(Shape.self, forKey: .shape) ?? .rounded,
                  width: try c.decode(Double.self, forKey: .width), height: try c.decode(Double.self, forKey: .height),
                  cavities: try c.decodeIfPresent([FaceCavity].self, forKey: .cavities) ?? [],
                  keys: try c.decodeIfPresent([Key].self, forKey: .keys) ?? [],
                  source: try c.decodeIfPresent(String.self, forKey: .source) ?? "")
        backdropPNG = try c.decodeIfPresent(Data.self, forKey: .backdropPNG)
        backdropMMPerPixel = try c.decodeIfPresent(Double.self, forKey: .backdropMMPerPixel)
        backdropOffset = try c.decodeIfPresent(Point2D.self, forKey: .backdropOffset)
    }
}
