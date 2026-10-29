import AppKit
import CrimpCore
import CrimpOutputs
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A connector's face drawn like a printed sheet (white card), with clickable cavities.
struct ConnectorFaceView: View {
    @ObservedObject var doc: HarnessDocument
    @EnvironmentObject var library: LibraryStore
    let connectorID: EntityID
    var wireSide = false
    var showLegend = true
    var selectedCavity: String?
    var maxScale: CGFloat = 1.6
    var onTap: ((String) -> Void)?

    var body: some View {
        if let c = doc.harness.connector(connectorID) {
            let drawing = makeDrawing(c)
            GeometryReader { geo in
                let scale = min(geo.size.width / drawing.width, geo.size.height / drawing.height, maxScale)
                let offset = CGPoint(x: (geo.size.width - drawing.width * scale) / 2, y: (geo.size.height - drawing.height * scale) / 2)
                Canvas { ctx, _ in
                    ctx.withCGContext { cg in
                        cg.translateBy(x: offset.x, y: offset.y)
                        cg.scaleBy(x: scale, y: scale)
                        cg.setFillColor(CGColor(gray: 1, alpha: 1))
                        cg.fill(CGRect(x: 0, y: 0, width: drawing.width, height: drawing.height))
                        FaceRenderer.draw(drawing, in: cg)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    let x = (p.x - offset.x) / scale, y = (p.y - offset.y) / scale
                    if let label = drawing.cavity(at: x, y) { onTap?(label) }
                }
            }
        }
    }

    private func makeDrawing(_ c: Connector) -> FaceDrawing {
        var o = FaceDrawingOptions()
        o.wireSide = wireSide
        o.showLegend = showLegend
        o.selectedCavity = selectedCavity
        return doc.harness.faceDrawing(for: c, layout: doc.harness.faceLayout(for: c, library: library.library), options: o)
    }
}

extension HarnessDocument {
    /// Saves a connector's face (with legend) as SVG.
    @MainActor
    func exportFaceSVG(_ connectorID: EntityID) {
        guard let c = harness.connector(connectorID) else { return }
        var o = FaceDrawingOptions()
        o.title = [c.id, c.name, c.part?.mpn].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let svg = harness.faceDrawing(for: c, layout: harness.faceLayout(for: c, library: LibraryStore.shared.library), options: o).svg()
        save(Data(svg.utf8), name: "\(c.id) face.svg", type: .svg)
    }
}

// MARK: - Layout editor

/// Builds a face layout from a preset, or by placing cavities over a datasheet image or PDF page.
/// Saves to the library part (every connector with that part number) or to this connector only.
struct FaceLayoutEditor: View {
    @ObservedObject var doc: HarnessDocument
    @EnvironmentObject var library: LibraryStore
    let connectorID: EntityID
    @Environment(\.dismiss) private var dismiss

    @State private var layout = FaceLayout(width: 20, height: 14, cavities: [])
    @State private var preset: FaceLayout.Preset = .twoRows
    @State private var columns = 2
    @State private var pitch = 5.0
    @State private var cavityDiameter = 3.2
    @State private var backdrop: NSImage?
    @State private var backdropOpacity = 0.6
    @State private var dragging: String?
    @State private var selected: String?
    @State private var pdfPage = 1
    @State private var pdfURL: URL?

    private var connector: Connector? { doc.harness.connector(connectorID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconTile(systemName: "circle.grid.cross", tint: Pane.connectors.tint, size: 34)
                Text("Connector Face — \(connectorID) \(connector?.part?.mpn ?? "")").font(.title2.weight(.semibold))
                Spacer()
                Text(layout.source).font(.caption).foregroundStyle(.secondary)
            }
            HSplitView {
                controls.frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
                editorCanvas.frame(minWidth: 480, minHeight: 420)
            }
            HStack {
                Text(unplaced.isEmpty ? "All \(connector?.cavities.count ?? 0) cavities placed." :
                     "Click on the face to place cavity \(unplaced[0]) (\(unplaced.count) left). Drag cavities to move them.")
                    .font(.callout).foregroundStyle(unplaced.isEmpty ? Color.secondary : Color.orange)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if connector?.part != nil {
                    Button("Save for This Connector Only") { saveToConnector() }
                    Button("Save to Library Part") { saveToLibrary() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .help("Every connector using \(connector?.part?.mpn ?? "this part") gets this face")
                } else {
                    Button("Save") { saveToConnector() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(width: 980, height: 660)
        .onAppear(perform: load)
    }

    // MARK: Controls

    private var controls: some View {
        Form {
            Section("Generate") {
                Picker("Arrangement", selection: $preset) {
                    ForEach(FaceLayout.Preset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if preset == .grid || preset == .staggered {
                    Stepper("Columns: \(columns)", value: $columns, in: 1...30)
                }
                LabeledContent("Pitch (mm)") { TextField("", value: $pitch, format: .number).frame(width: 60) }
                LabeledContent("Cavity Ø (mm)") { TextField("", value: $cavityDiameter, format: .number).frame(width: 60) }
                Button("Generate Layout") { generate() }
            }
            Section("Housing") {
                Picker("Shape", selection: $layout.shape) {
                    ForEach(FaceLayout.Shape.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                LabeledContent("Width (mm)") { TextField("", value: $layout.width, format: .number).frame(width: 60) }
                LabeledContent("Height (mm)") { TextField("", value: $layout.height, format: .number).frame(width: 60) }
                Picker("Key / latch", selection: keyPosition) {
                    Text("Top").tag(0); Text("Bottom").tag(1); Text("None").tag(2)
                }
            }
            Section("Trace from datasheet") {
                HStack {
                    Button("Image…") { loadImage() }
                    Button("PDF Page…") { loadPDF() }
                }
                if pdfURL != nil {
                    Stepper("Page \(pdfPage)", value: $pdfPage, in: 1...999).onChange(of: pdfPage) { renderPDFPage() }
                }
                if backdrop != nil {
                    Slider(value: $backdropOpacity, in: 0.1...1) { Text("Opacity") }
                    Text("The image is stretched to the housing outline. Crop it to the mating face first, set the housing size in mm, then place each cavity on its hole.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Clear Cavities") { layout.cavities = [] }
                        Button("Remove Image") { backdrop = nil }
                    }
                }
            }
            if let s = selected, layout.cavity(s) != nil {
                Section("Cavity \(s)") {
                    Button("Remove Cavity \(s)", role: .destructive) {
                        layout.cavities.removeAll { $0.label == s }
                        selected = nil
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var keyPosition: Binding<Int> {
        Binding(get: {
            guard let k = layout.keys.first else { return 2 }
            return k.y < 0 ? 0 : 1
        }, set: { v in
            let w = layout.width * 0.4
            switch v {
            case 0: layout.keys = [.init(x: -w / 2, y: -layout.height / 2 - 1.6, width: w, height: 1.6)]
            case 1: layout.keys = [.init(x: -w / 2, y: layout.height / 2, width: w, height: 1.6)]
            default: layout.keys = []
            }
        })
    }

    // MARK: Canvas

    private var editorCanvas: some View {
        GeometryReader { geo in
            let s = min((geo.size.width - 40) / max(layout.width, 1), (geo.size.height - 40) / max(layout.height + 4, 1))
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let box = CGRect(x: center.x - layout.width * s / 2, y: center.y - layout.height * s / 2, width: layout.width * s, height: layout.height * s)
            ZStack {
                Color.white
                if let backdrop {
                    Image(nsImage: backdrop).resizable().frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY).opacity(backdropOpacity)
                }
                Canvas { ctx, _ in
                    let outline: Path = layout.shape == .circle ? Path(ellipseIn: box)
                        : Path(roundedRect: box, cornerRadius: layout.shape == .rounded ? min(box.width, box.height) * 0.12 : 0)
                    if backdrop == nil { ctx.fill(outline, with: .color(Color(white: 0.91))) }
                    ctx.stroke(outline, with: .color(.black), lineWidth: 1.5)
                    for k in layout.keys {
                        ctx.fill(Path(CGRect(x: center.x + k.x * s, y: center.y + k.y * s, width: k.width * s, height: k.height * s)), with: .color(.black))
                    }
                    for fc in layout.cavities {
                        let r = fc.diameter * s / 2
                        let rect = CGRect(x: center.x + fc.x * s - r, y: center.y + fc.y * s - r, width: 2 * r, height: 2 * r)
                        ctx.fill(Path(ellipseIn: rect), with: .color(fc.label == selected ? .accentColor.opacity(0.5) : .white.opacity(0.85)))
                        ctx.stroke(Path(ellipseIn: rect), with: .color(fc.label == selected ? .accentColor : .black), lineWidth: fc.label == selected ? 2.5 : 1.2)
                        ctx.draw(Text(fc.label).font(.system(size: max(9, min(14, r))).bold()).foregroundStyle(.black), at: CGPoint(x: rect.midX, y: rect.midY))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let mm = CGPoint(x: (v.location.x - center.x) / s, y: (v.location.y - center.y) / s)
                        if dragging == nil {
                            let start = CGPoint(x: (v.startLocation.x - center.x) / s, y: (v.startLocation.y - center.y) / s)
                            dragging = layout.cavities.first { hypot($0.x - start.x, $0.y - start.y) <= $0.diameter / 2 + 0.5 }?.label ?? ""
                        }
                        if let d = dragging, !d.isEmpty, let i = layout.cavities.firstIndex(where: { $0.label == d }),
                           hypot(v.translation.width, v.translation.height) > 2 {
                            layout.cavities[i].x = (mm.x * 10).rounded() / 10
                            layout.cavities[i].y = (mm.y * 10).rounded() / 10
                        }
                    }
                    .onEnded { v in
                        defer { dragging = nil }
                        guard hypot(v.translation.width, v.translation.height) <= 2 else { return }
                        let mm = CGPoint(x: (v.location.x - center.x) / s, y: (v.location.y - center.y) / s)
                        if let hit = layout.cavities.first(where: { hypot($0.x - mm.x, $0.y - mm.y) <= $0.diameter / 2 + 0.5 }) {
                            selected = hit.label
                        } else if let next = unplaced.first {
                            layout.cavities.append(.init(label: next, x: (mm.x * 10).rounded() / 10, y: (mm.y * 10).rounded() / 10, diameter: cavityDiameter))
                            layout.source = backdrop == nil ? "Placed by hand" : "Traced from datasheet"
                            selected = next
                        }
                    })
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Actions

    private var unplaced: [String] {
        let placed = Set(layout.cavities.map(\.label))
        return (connector?.cavities.map(\.label) ?? []).filter { !placed.contains($0) }
    }

    private func load() {
        guard let c = connector else { return }
        layout = doc.harness.faceLayout(for: c, library: library.library)
        if let png = layout.backdropPNG { backdrop = NSImage(data: png) }
        columns = c.gridColumns ?? max(1, Int(Double(c.cavities.count).squareRoot().rounded(.up)))
        cavityDiameter = layout.cavities.first?.diameter ?? 3.2
    }

    private func generate() {
        guard let c = connector else { return }
        let keys = layout.keys
        let shape = layout.shape
        layout = FaceLayout.preset(preset, labels: c.cavities.map(\.label), columns: columns, pitch: pitch, cavityDiameter: cavityDiameter)
        if preset != .circular { layout.shape = shape == .circle ? .rounded : shape }
        if keys.isEmpty { layout.keys = [] }
    }

    private func loadImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.message = "Choose an image of the connector's mating face (a datasheet crop or photo)."
        guard panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return }
        backdrop = img
        pdfURL = nil
        fitHousingToImage(img)
    }

    private func loadPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = "Choose the connector datasheet PDF; then pick the page showing the mating face."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pdfURL = url
        pdfPage = 1
        renderPDFPage()
    }

    private func renderPDFPage() {
        guard let url = pdfURL, let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { return }
        let page = pdf.page(at: min(pdfPage, pdf.pageCount) - 1)!
        let bounds = page.bounds(for: .mediaBox)
        backdrop = page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
    }

    /// Keeps the housing's aspect ratio equal to the image's so traced positions are not distorted.
    private func fitHousingToImage(_ img: NSImage) {
        guard img.size.width > 0, img.size.height > 0 else { return }
        layout.height = (layout.width * img.size.height / img.size.width * 10).rounded() / 10
    }

    private func finished() -> FaceLayout {
        var l = layout
        if let backdrop, let tiff = backdrop.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            l.backdropPNG = rep.representation(using: .png, properties: [:])
        } else {
            l.backdropPNG = nil
        }
        return l
    }

    private func saveToConnector() {
        let l = finished()
        doc.perform("Edit Face of \(connectorID)") { h in
            if let i = h.connectors.firstIndex(where: { $0.id == connectorID }) { h.connectors[i].faceLayout = l }
        }
        dismiss()
    }

    private func saveToLibrary() {
        guard let part = connector?.part else { return saveToConnector() }
        var l = finished()
        l.backdropPNG = nil      // keep the shared library light; the trace image stays with the connector
        if var entry = library.library.entry(for: part) {
            entry.faceLayout = l
            library.library.upsert(entry)
        } else {
            library.library.upsert(LibraryPart(part: part, category: "connector", cavityCount: connector?.cavities.count, faceLayout: l))
        }
        // A connector-only override would hide the shared layout.
        doc.perform("Use Library Face for \(connectorID)") { h in
            if let i = h.connectors.firstIndex(where: { $0.id == connectorID }) { h.connectors[i].faceLayout = nil }
        }
        doc.objectWillChange.send()
        dismiss()
    }
}

struct FaceEditTarget: Identifiable {
    let id: EntityID
}
