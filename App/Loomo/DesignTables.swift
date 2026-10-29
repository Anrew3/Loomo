import CrimpCore
import SwiftUI

/// Maps a table's single selection onto the document's selection.
@MainActor
func selectionBinding(_ doc: HarnessDocument, _ make: @escaping (EntityID) -> Selection) -> Binding<EntityID?> {
    Binding(
        get: {
            guard let s = doc.selection else { return nil }
            return make(s.id) == s ? s.id : nil
        },
        set: { doc.selection = $0.map(make) })
}

// MARK: - Wires

struct WiresTable: View {
    @ObservedObject var doc: HarnessDocument
    @State private var selected: Set<EntityID> = []
    @State private var sortOrder = [KeyPathComparator(\Wire.id, comparator: .localizedStandard)]
    @State private var bulkExtra: Double = 0

    var body: some View {
        let routes = doc.analysis.routes
        let u = doc.units
        let twistOf = Dictionary(doc.harness.twists.flatMap { t in t.wireIDs.map { ($0, t.id) } }, uniquingKeysWith: { a, _ in a })
        VStack(spacing: 0) {
            Table(doc.harness.wires.sorted(using: sortOrder), selection: $selected, sortOrder: $sortOrder) {
                TableColumn("ID", value: \.id, comparator: .localizedStandard).width(48)
                TableColumn("Signal") { Text($0.signal ?? "") }
                TableColumn("From") { Text($0.from.description).foregroundStyle($0.from == .unassigned ? Color.orange : Color.primary) }
                TableColumn("To") { Text($0.to.description).foregroundStyle($0.to == .unassigned ? Color.orange : Color.primary) }
                TableColumn("Size") { Text($0.size.description) }.width(70)
                TableColumn("Colour") { w in HStack(spacing: 4) { WireDot(color: w.color).frame(width: 11, height: 11); Text(w.color.description) } }.width(80)
                TableColumn("Cable / twist") { w in Text([w.cableID, twistOf[w.id]].compactMap { $0 }.joined(separator: " · ")) }.width(90)
                TableColumn("Route") { Text(routes[$0.id]?.segmentIDs.joined(separator: "→") ?? "") }
                TableColumn("Length") { w in
                    let r = routes[w.id]
                    Text(u.format(r?.lengthMM) + (r?.isOverridden == true ? " *" : ""))
                        .foregroundStyle(r?.lengthMM == nil ? .red : .primary).monospacedDigit()
                }.width(80)
            }
            .contextMenu(forSelectionType: EntityID.self) { ids in
                let list = Array(ids).sorted(by: naturalLess)
                if ids.count >= 2 {
                    Button("Twist \(list.joined(separator: ", "))") { doc.perform("Twist") { $0.twist(list) } }
                    Button("Make Cable") { doc.perform("Make Cable") { h in let id = h.makeCable(from: list); doc.selection = .cable(id) } }
                }
                if !ids.isEmpty {
                    Button("Untwist") { doc.perform("Untwist") { $0.untwist(list) } }
                    Button("Unassign Both Ends") {
                        doc.perform("Unassign Ends") { h in for w in list { h.unassign(WireEnd(w, .a)); h.unassign(WireEnd(w, .b)) } }
                    }
                    Button("Clear Length Overrides") {
                        doc.perform("Clear Length Overrides") { h in
                            for i in h.wires.indices where ids.contains(h.wires[i].id) { h.wires[i].lengthOverrideMM = nil }
                        }
                    }
                    Divider()
                    Button(ids.count == 1 ? "Delete Wire" : "Delete \(ids.count) Wires", role: .destructive) { doc.deleteItems(ids) }
                } else {
                    Button("Add Wire…") { doc.requestWire() }
                }
            }
            .onDeleteCommand { doc.deleteItems(selected) }
            .onChange(of: selected) {
                doc.multiSelection = selected
                if selected.count == 1, let id = selected.first { doc.selection = .wire(id) }
            }
            // Reflect a wire selected elsewhere (trace links, rule checker, canvas).
            .onAppear { syncFromDocument() }
            .onChange(of: doc.selection) { syncFromDocument() }
            Divider()
            actionBar
        }
    }

    private func syncFromDocument() {
        if case let .wire(id)? = doc.selection, !selected.contains(id) { selected = [id] }
    }

    private var actionBar: some View {
        let ids = Array(selected).sorted(by: naturalLess)
        return HStack(spacing: 8) {
            Text(ids.isEmpty ? "Select wires for bulk actions (⌘-click for several)." : "\(ids.count) selected")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Twist") { doc.perform("Twist \(ids.joined(separator: ", "))") { $0.twist(ids) } }.disabled(ids.count < 2)
            Button("Untwist") { doc.perform("Untwist") { $0.untwist(ids) } }.disabled(ids.isEmpty)
            Button("Make Cable") { doc.perform("Make Cable") { h in let id = h.makeCable(from: ids); doc.selection = .cable(id) } }.disabled(ids.isEmpty)
            Divider().frame(height: 16)
            TextField("Extra", value: $bulkExtra, format: .number).frame(width: 56)
            Button("Set Extra Length") {
                doc.perform("Set Extra Length") { h in
                    for i in h.wires.indices where ids.contains(h.wires[i].id) { h.wires[i].extraLengthMM = doc.units.toMM(bulkExtra) }
                }
            }.disabled(ids.isEmpty)
            Button("Clear Overrides") {
                doc.perform("Clear Length Overrides") { h in
                    for i in h.wires.indices where ids.contains(h.wires[i].id) { h.wires[i].lengthOverrideMM = nil }
                }
            }.disabled(ids.isEmpty)
            Button("Add Wire…") { doc.requestWire() }
        }
        .padding(8)
    }
}

// MARK: - Cables and twists

struct CablesPane: View {
    @ObservedObject var doc: HarnessDocument

    var body: some View {
        let h = doc.harness, a = doc.analysis
        VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Cables").font(.headline).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                Table(h.cables, selection: selectionBinding(doc, Selection.cable)) {
                    TableColumn("ID", value: \.id).width(50)
                    TableColumn("Name", value: \.name)
                    TableColumn("Part") { Text($0.part?.mpn ?? "—") }
                    TableColumn("Shielded") { Text($0.shielded ? "Yes" : "") }.width(60)
                    TableColumn("Jacket Ø") { Text(String(format: "%.1f mm", $0.jacketODMM)) }.width(70)
                    TableColumn("Cores") { c in Text(h.wires.filter { $0.cableID == c.id }.map(\.id).joined(separator: ", ")) }
                    TableColumn("Jacket length") { c in Text(doc.units.format(HarnessAnalysis.cableJacketLength(c, h, a.routes))) }
                }
            .onDeleteCommand { doc.deleteSelection() }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Twists").font(.headline).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                Table(h.twists, selection: selectionBinding(doc, Selection.twist)) {
                    TableColumn("ID", value: \.id).width(50)
                    TableColumn("Wires") { Text($0.wireIDs.joined(separator: ", ")) }
                    TableColumn("Lay length") { Text(doc.units.format($0.layLengthMM)) }
                    TableColumn("Take-up") { t in
                        Text(t.wireIDs.compactMap { a.routes[$0]?.twistTakeUpMM }.max().map { doc.units.format($0, decimals: 1) } ?? "—")
                    }
                }
            .onDeleteCommand { doc.deleteSelection() }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("Create cables and twists by selecting wires on the Wires page.").font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }
}

// MARK: - Splices, coverings, labels

struct SplicesTable: View {
    @ObservedObject var doc: HarnessDocument

    var body: some View {
        let h = doc.harness
        Table(h.splices, selection: selectionBinding(doc, Selection.splice)) {
            TableColumn("ID", value: \.id).width(50)
            TableColumn("Kind") { Text($0.kind.title) }
            TableColumn("Value") { Text($0.value ?? "") }
            TableColumn("Part") { Text($0.part?.mpn ?? "—") }
            TableColumn("Heat shrink") { Text($0.heatShrink?.mpn ?? "—") }
            TableColumn("Wires") { s in
                Text(h.wires.filter { $0.from == .splice(s.id) || $0.to == .splice(s.id) }.map(\.id).joined(separator: ", "))
            }
            TableColumn("Total mm²") { s in
                Text(String(format: "%.2f", h.wires.filter { $0.from == .splice(s.id) || $0.to == .splice(s.id) }.map(\.size.crossSectionMM2).reduce(0, +)))
            }.width(70)
        }
            .onDeleteCommand { doc.deleteSelection() }
    }
}

struct CoveringsTable: View {
    @ObservedObject var doc: HarnessDocument

    var body: some View {
        let h = doc.harness, a = doc.analysis
        Table(h.coverings, selection: selectionBinding(doc, Selection.covering)) {
            TableColumn("ID", value: \.id).width(45)
            TableColumn("Kind") { Text($0.kind.title) }
            TableColumn("Part") { Text($0.part?.mpn ?? "—") }
            TableColumn("Segments") { Text($0.segmentIDs.joined(separator: ", ")) }
            TableColumn("Wrap / size") { c in
                Text(c.tape.map { "\($0.style.rawValue) \(Int($0.widthMM)) mm" } ?? (c.innerDiameterMM.map { "ID \($0) mm" } ?? ""))
            }
            TableColumn("Max bundle Ø") { c in Text(String(format: "%.1f mm", c.segmentIDs.compactMap { a.bundleDiameterMM[$0] }.max() ?? 0)) }
            TableColumn("Material") { c in Text(doc.units.format(HarnessAnalysis.coveringQuantityMM(c, in: h, bundle: a.bundleDiameterMM))).monospacedDigit() }
        }
            .onDeleteCommand { doc.deleteSelection() }
    }
}

struct LabelsTable: View {
    @ObservedObject var doc: HarnessDocument

    var body: some View {
        let h = doc.harness
        VStack(spacing: 0) {
            Table(h.labels, selection: selectionBinding(doc, Selection.label)) {
                TableColumn("ID", value: \.id).width(45)
                TableColumn("Text") { l in
                    Text(HarnessAnalysis.labelText(l, h)) + Text(l.text == nil ? "  (synced)" : "").foregroundStyle(.secondary)
                }
                TableColumn("Placement") { l in
                    switch l.placement {
                    case let .segment(s, off): Text("\(s) @ \(doc.units.format(off))")
                    case let .connector(c): Text("at \(c)")
                    }
                }
                TableColumn("Part") { Text($0.part?.mpn ?? "—") }
            }
            .onDeleteCommand { doc.deleteSelection() }
            Divider()
            HStack {
                Text("Place bundle labels with the label tool on the drawing.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Label Every Connector") {
                    doc.perform("Label Connectors") { h in
                        for c in h.connectors where !h.labels.contains(where: { $0.placement == .connector(c.id) }) {
                            h.labels.append(BundleLabel(id: h.nextID(prefix: "L"), placement: .connector(c.id)))
                        }
                    }
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Notes, revisions, title block, tools, annotations

struct DrawingInfoPane: View {
    @ObservedObject var doc: HarnessDocument

    var body: some View {
        Form {
            Section("Title block") {
                TextField("Harness name", text: $doc.harness.name)
                TextField("Revision", text: $doc.harness.revision)
                TextField("Company", text: $doc.harness.titleBlock.company)
                TextField("Drawing number", text: $doc.harness.titleBlock.drawingNumber)
                TextField("Drawn by", text: $doc.harness.titleBlock.drawnBy)
                TextField("Checked by", text: $doc.harness.titleBlock.checkedBy)
                TextField("Approved by", text: $doc.harness.titleBlock.approvedBy)
                Picker("Sheet size", selection: $doc.harness.titleBlock.sheetSize) {
                    ForEach(SheetSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Logo") {
                    HStack {
                        if let data = doc.harness.titleBlock.logoPNG, let img = NSImage(data: data) {
                            Image(nsImage: img).resizable().scaledToFit().frame(height: 28)
                        }
                        Button("Choose…") { chooseLogo() }
                        if doc.harness.titleBlock.logoPNG != nil { Button("Remove") { doc.harness.titleBlock.logoPNG = nil } }
                    }
                }
                Picker("Units", selection: $doc.harness.settings.units) {
                    Text("Metric (mm)").tag(UnitSystem.metric)
                    Text("Imperial (in)").tag(UnitSystem.imperial)
                }
            }
            Section("Notes (drawn as numbered flags)") {
                ForEach($doc.harness.notes) { $note in
                    HStack(alignment: .top) {
                        Text("\(note.id).").bold().frame(width: 24)
                        VStack(alignment: .leading) {
                            TextField("Note", text: $note.text, axis: .vertical)
                            TextField("Flag on (ids, comma separated)", text: Binding(
                                get: { note.attachedTo.joined(separator: ", ") },
                                set: { note.attachedTo = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                                .font(.caption)
                        }
                        Button(role: .destructive) { doc.perform("Delete Note") { h in h.notes.removeAll { $0.id == note.id } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Note") {
                    doc.perform("Add Note") { h in h.notes.append(DrawingNote(id: (h.notes.map(\.id).max() ?? 0) + 1, text: "")) }
                }
            }
            Section("Revisions") {
                ForEach($doc.harness.revisions) { $r in
                    HStack {
                        TextField("Rev", text: $r.rev).frame(width: 50)
                        TextField("Date", text: $r.date).frame(width: 100)
                        TextField("Description", text: $r.description)
                        TextField("By", text: $r.author).frame(width: 90)
                    }
                }
                Button("Add Revision") {
                    doc.perform("Add Revision") { h in
                        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
                        h.revisions.append(Revision(rev: h.revision, date: date, description: "", author: h.titleBlock.drawnBy))
                    }
                }
            }
            Section("Tools, fixtures and equipment") {
                ForEach($doc.harness.tools) { $t in
                    HStack {
                        Picker("", selection: $t.kind) {
                            ForEach(ToolKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 120)
                        TextField("Name", text: $t.name)
                        TextField("Part number", text: $t.partNumber)
                        TextField("Notes", text: $t.notes)
                    }
                }
                Button("Add Tool") { doc.perform("Add Tool") { h in h.tools.append(ToolItem(id: h.nextID(prefix: "TL"), kind: .fixture, name: "")) } }
                Text("Crimp tools also come from each terminal's crimp tool field.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Manufacturing rules") {
                LengthField("Termination allowance per end", mm: $doc.harness.settings.terminationAllowanceMM, units: doc.units)
                NumberField("Covering material margin (%)", value: $doc.harness.settings.materialMarginPercent)
                NumberField("Bundle packing factor", value: $doc.harness.settings.bundlePackingFactor)
                LengthField("Cut length rounding", mm: $doc.harness.settings.cutLengthRoundingMM, units: doc.units)
                NumberField("Grid size (pt)", value: $doc.harness.settings.gridSize)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        guard panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        doc.perform("Set Logo") { $0.titleBlock.logoPNG = png }
    }
}
