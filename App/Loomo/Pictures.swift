import AppKit
import CrimpCore
import SwiftUI

struct CropTarget: Identifiable {
    var id: EntityID { connectorID }
    var connectorID: EntityID
    /// A picture just chosen, not yet stored on the connector; nil crops the connector's current picture.
    var image: NSImage? = nil
}

struct PassThroughRequest: Identifiable {
    var id: String { a + "|" + b }
    var a: EntityID
    var b: EntityID
}

extension HarnessDocument {
    /// Picks a picture for a connector (for example a photo of an OEM connector), then offers to crop it.
    func chooseConnectorPicture(_ id: EntityID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.message = "Choose a picture for \(id). You can crop it next."
        guard panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return }
        cropTarget = CropTarget(connectorID: id, image: img)
    }

    func requestPassThrough(_ a: EntityID, _ b: EntityID) {
        passThrough = PassThroughRequest(a: a, b: b)
    }
}

extension NSImage {
    var png: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// The part of the image inside `rect`, given in 0…1 of the image's width and height (top-left origin).
    func cropped(to rect: CGRect) -> NSImage? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let px = CGRect(x: rect.minX * w, y: rect.minY * h, width: rect.width * w, height: rect.height * h).integral
        guard let part = cg.cropping(to: px) else { return nil }
        return NSImage(cgImage: part, size: NSSize(width: part.width, height: part.height))
    }
}

/// Crops a connector's picture: drag the corners or the box, then Save.
struct ConnectorPictureCropSheet: View {
    @ObservedObject var doc: HarnessDocument
    let target: CropTarget
    @Environment(\.dismiss) private var dismiss
    /// Crop box in 0…1 of the image (top-left origin).
    @State private var crop = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    @State private var dragStart: CGRect?

    private var image: NSImage? {
        target.image ?? doc.harness.connector(target.connectorID)?.imagePNG.flatMap { NSImage(data: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Picture for \(target.connectorID)").font(.title3.weight(.semibold))
            Text("Drag the corners to crop, or drag inside the box to move it. The cropped picture replaces the part photo on the drawing.")
                .font(.callout).foregroundStyle(.secondary)
            if let image {
                GeometryReader { geo in
                    let fit = fitted(image.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().frame(width: fit.width, height: fit.height)
                        // Dim everything outside the crop box.
                        Path { p in
                            p.addRect(CGRect(origin: .zero, size: fit))
                            p.addRect(box(fit))
                        }
                        .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                        Rectangle()
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .frame(width: box(fit).width, height: box(fit).height)
                            .offset(x: box(fit).minX, y: box(fit).minY)
                            .gesture(DragGesture().onChanged { v in move(by: v.translation, in: fit) }.onEnded { _ in dragStart = nil })
                        ForEach(0..<4, id: \.self) { corner in
                            let c = cornerPoint(corner, box(fit))
                            Circle().fill(Color.accentColor).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .offset(x: c.x - 7, y: c.y - 7)
                                .gesture(DragGesture().onChanged { v in resize(corner, by: v.translation, in: fit) }.onEnded { _ in dragStart = nil })
                        }
                    }
                    .frame(width: fit.width, height: fit.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 520, minHeight: 380)
            } else {
                ContentUnavailableView("No picture", systemImage: "photo")
            }
            HStack {
                Button("Use Whole Picture") { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(image == nil)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }

    private func fitted(_ size: NSSize, in space: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return space }
        let s = min(space.width / size.width, space.height / size.height)
        return CGSize(width: size.width * s, height: size.height * s)
    }

    private func box(_ fit: CGSize) -> CGRect {
        CGRect(x: crop.minX * fit.width, y: crop.minY * fit.height, width: crop.width * fit.width, height: crop.height * fit.height)
    }

    private func cornerPoint(_ i: Int, _ r: CGRect) -> CGPoint {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)][i]
    }

    private func move(by t: CGSize, in fit: CGSize) {
        let start = dragStart ?? crop
        dragStart = start
        var r = start.offsetBy(dx: t.width / fit.width, dy: t.height / fit.height)
        r.origin.x = min(max(0, r.minX), 1 - r.width)
        r.origin.y = min(max(0, r.minY), 1 - r.height)
        crop = r
    }

    private func resize(_ corner: Int, by t: CGSize, in fit: CGSize) {
        let start = dragStart ?? crop
        dragStart = start
        let dx = t.width / fit.width, dy = t.height / fit.height
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        if corner == 0 || corner == 3 { minX = min(max(0, minX + dx), maxX - 0.05) } else { maxX = max(min(1, maxX + dx), minX + 0.05) }
        if corner == 0 || corner == 1 { minY = min(max(0, minY + dy), maxY - 0.05) } else { maxY = max(min(1, maxY + dy), minY + 0.05) }
        crop = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func save() {
        guard let image, let cut = image.cropped(to: crop), let png = cut.png else { return }
        doc.perform("Set Picture for \(target.connectorID)") { h in
            if let i = h.connectors.firstIndex(where: { $0.id == target.connectorID }) { h.connectors[i].imagePNG = png }
        }
        dismiss()
    }
}

/// Wires two connectors pin to pin (a T-harness or pass-through: IPC IN ↔ IPC OUT).
struct PassThroughSheet: View {
    @ObservedObject var doc: HarnessDocument
    let request: PassThroughRequest
    @Environment(\.dismiss) private var dismiss
    @AppStorage("newWire.size") private var size = "awg20"
    @AppStorage("newWire.color") private var colorBase = "BK"
    @State private var byOrder = false
    @State private var includeUsed = false
    @State private var error: String?

    var body: some View {
        let h = doc.harness
        let a = h.connector(request.a), b = h.connector(request.b)
        let pairs = (a?.cavities ?? []).enumerated().compactMap { i, cav -> (String, String)? in
            if byOrder { return b.flatMap { i < $0.cavities.count ? (cav.label, $0.cavities[i].label) : nil } }
            return b?.cavities.contains { $0.label == cav.label } == true ? (cav.label, cav.label) : nil
        }
        VStack(alignment: .leading, spacing: 14) {
            Text("Pass-through wires \(request.a) ↔ \(request.b)").font(.title3.weight(.semibold))
            Text("One wire from each cavity of \(request.a) to the matching cavity of \(request.b), carrying the cavity's signal name.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("Match cavities", selection: $byOrder) {
                    Text("By label (1 → 1, A → A)").tag(false)
                    Text("By position").tag(true)
                }
                Picker("Size", selection: $size) {
                    ForEach([26, 24, 22, 20, 18, 16, 14, 12, 10], id: \.self) { Text("\($0) AWG").tag("awg\($0)") }
                    ForEach([0.35, 0.5, 0.75, 1.0, 1.5, 2.5, 4.0], id: \.self) { Text(String(format: "%g mm²", $0)).tag("mm\($0)") }
                }
                Picker("Colour", selection: $colorBase) { ForEach(WireTables.colorOrder, id: \.self) { Text(colorLabel($0)).tag($0) } }
                Toggle("Also wire cavities that already have a wire", isOn: $includeUsed)
                LabeledContent("Wires to add", value: "\(pairs.count)")
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Wires") { add() }.keyboardShortcut(.defaultAction).disabled(pairs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func add() {
        let wireSize: WireSize = size.hasPrefix("awg") ? .awg(Int(size.dropFirst(3)) ?? 20) : WireSize(mm2: Double(size.dropFirst(2)) ?? 0.5)
        do {
            var made: [EntityID] = []
            var copy = doc.harness
            made = try copy.passThrough(from: request.a, to: request.b, size: wireSize, color: WireColor(colorBase),
                                        includeUsed: includeUsed, matchByOrder: byOrder)
            guard !made.isEmpty else { error = "Every matching cavity already has a wire."; return }
            doc.perform("Pass-Through \(request.a) ↔ \(request.b)") { $0 = copy }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension Notification.Name {
    /// Switches a harness window to its drawing (object: the document).
    static let showDrawing = Notification.Name("LoomoShowDrawing")
}
