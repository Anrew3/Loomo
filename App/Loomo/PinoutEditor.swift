import CrimpCore
import SwiftUI

/// Connectors table on top, the selected connector's pinout below.
struct ConnectorsPane: View {
    @ObservedObject var doc: HarnessDocument

    var body: some View {
        VSplitView {
            ConnectorsTable(doc: doc)
                .frame(maxWidth: .infinity, minHeight: 140, idealHeight: 200)
            Group {
                if case let .connector(id)? = doc.selection, doc.harness.connector(id) != nil {
                    PinoutEditor(doc: doc, connectorID: id)
                } else {
                    ContentUnavailableView("Select a connector", systemImage: "powerplug",
                                           description: Text("Its cavity grid appears here. Click a wire end, then a cavity, to assign it."))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        }
    }
}

struct ConnectorsTable: View {
    @ObservedObject var doc: HarnessDocument
    @State private var filter = ""

    private var shown: [Connector] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return doc.harness.connectors }
        return doc.harness.connectors.filter { c in
            [c.id, c.name, c.part?.mpn ?? "", c.part?.manufacturer ?? "", c.kind.title].contains { $0.lowercased().contains(q) }
                || c.cavities.contains { ($0.signal ?? "").lowercased().contains(q) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter by designator, name, part or signal", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                if !filter.isEmpty { Text("\(shown.count) of \(doc.harness.connectors.count)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            .padding(8)
            connectorTable
        }
    }

    private var connectorTable: some View {
        Table(shown, selection: selectionBinding(doc, Selection.connector)) {
            TableColumn("ID", value: \.id).width(50)
            TableColumn("Name", value: \.name)
            TableColumn("Kind") { Text($0.kind.title) }
            TableColumn("Part") { Text($0.part?.mpn ?? "—") }
            TableColumn("Manufacturer") { Text($0.part?.manufacturer ?? "—") }
            TableColumn("Ways") { Text("\($0.cavities.count)") }.width(45)
            TableColumn("Sealed") { Text($0.sealed ? "Yes" : "") }.width(50)
            TableColumn("Wires") { c in
                Text("\(doc.harness.wires.filter { $0.from.connectorID == c.id || $0.to.connectorID == c.id }.count)")
            }.width(45)
        }
        .contextMenu(forSelectionType: EntityID.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Change Part…") { doc.placement = .init(mode: .replacePart(id)) }
                Button("Remap Connections…") { doc.remap = RemapRequest(from: id) }
                Button("Add Wire from \(id)") {
                    doc.addWire(from: .pin(connector: id, cavity: doc.harness.connector(id)?.cavities.first?.label ?? "1"))
                }
                Button("Duplicate") { doc.selection = .connector(id); doc.multiSelection = []; doc.duplicateSelection() }
            }
            if !ids.isEmpty {
                Divider()
                Button(ids.count == 1 ? "Delete" : "Delete \(ids.count) Connectors", role: .destructive) { doc.deleteItems(ids) }
            }
        } primaryAction: { ids in
            if let id = ids.first { doc.selection = .connector(id) }
        }
        .onDeleteCommand { doc.deleteSelection() }
        .sheet(item: $doc.placement) { PlacePartSheet(doc: doc, placement: $0) }
    }
}

/// Click-to-assign cavity grid. A wire end is "armed" from the palette (or a new wire is started),
/// then clicking a cavity places it there; dropping onto an occupied cavity swaps.
struct PinoutEditor: View {
    @ObservedObject var doc: HarnessDocument
    let connectorID: EntityID

    @State private var selectedCavity: String?
    @State private var armed: WireEnd?
    @State private var filter = ""
    @State private var fromWireSide = false
    @AppStorage("pinoutShowsFace") private var showFace = false

    private var connector: Connector? { doc.harness.connector(connectorID) }

    var body: some View {
        if let c = connector {
            HSplitView {
                VStack(spacing: 0) {
                    header(c)
                    Divider()
                    if showFace {
                        ConnectorFaceView(doc: doc, connectorID: connectorID, wireSide: fromWireSide,
                                          selectedCavity: selectedCavity, onTap: tapped)
                            .padding(12)
                    } else {
                        ScrollView([.vertical, .horizontal]) {
                            grid(c).padding(16)
                        }
                    }
                    Divider()
                    legend
                }
                .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                sidePanel(c)
                    .frame(minWidth: 220, idealWidth: 300, maxWidth: 420, maxHeight: .infinity)
            }
        }
    }

    // MARK: Header and grid

    private func header(_ c: Connector) -> some View {
        HStack(spacing: 12) {
            if let url = c.part.flatMap(LibraryStore.shared.photoURL) { PartPhoto(url: url, size: 44) }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(c.id)  \(c.name)").font(.headline)
                Text([c.kind.title, c.part?.mpn, c.part?.manufacturer].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Display", selection: $showFace) {
                Label("Grid", systemImage: "square.grid.3x3").tag(false)
                Label("Face", systemImage: "circle.grid.cross").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Grid shows cavities as cards; Face draws the connector's mating face with colour-coded wires")
            if showFace {
                Button("Edit Face…") { doc.faceEditor = FaceEditTarget(id: connectorID) }
                Button { doc.exportFaceSVG(connectorID) } label: { Image(systemName: "square.and.arrow.up") }.help("Export face as SVG")
            }
            Picker("View", selection: $fromWireSide) {
                Text("Mating face").tag(false)
                Text("Wire side").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Wire side mirrors the grid left-to-right, as seen when inserting contacts")
            Stepper("Columns: \(columns(c))", value: Binding(
                get: { columns(c) },
                set: { n in doc.perform("Change Grid") { h in
                    if let i = h.connectors.firstIndex(where: { $0.id == connectorID }) { h.connectors[i].gridColumns = n }
                } }), in: 1...max(1, c.cavities.count))
                .fixedSize()
            if armed != nil {
                Button("Cancel") { armed = nil }.keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(10)
    }

    private func columns(_ c: Connector) -> Int {
        c.gridColumns ?? max(1, Int(Double(c.cavities.count).squareRoot().rounded(.up)))
    }

    private func grid(_ c: Connector) -> some View {
        let cols = columns(c)
        let rows = stride(from: 0, to: c.cavities.count, by: cols).map { Array(c.cavities[$0..<min($0 + cols, c.cavities.count)]) }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(fromWireSide ? row.reversed() : row, id: \.label) { cav in
                        cell(c, cav)
                    }
                }
            }
        }
    }

    private func cell(_ c: Connector, _ cav: Cavity) -> some View {
        let here = Endpoint.pin(connector: c.id, cavity: cav.label)
        let ends = doc.harness.wireEnds(at: here)
        let wire = ends.first.flatMap { doc.harness.wire($0.wireID) }
        let isSelected = selectedCavity == cav.label
        let missingTerminal = !ends.isEmpty && cav.terminal == nil && c.kind != .device && !c.kind.isLooseTerminal
        let missingSeal = c.sealed && !ends.isEmpty && cav.seal == nil
        let missingPlug = c.sealed && ends.isEmpty && cav.plug == nil

        return VStack(spacing: 3) {
            Text(cav.label).font(.caption.bold())
            ZStack {
                Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 34, height: 34)
                if let wire {
                    WireDot(color: wire.color).frame(width: 30, height: 30)
                } else if cav.plug != nil {
                    Image(systemName: "circle.fill").font(.system(size: 22)).foregroundStyle(.gray.opacity(0.5))
                }
                if ends.count > 1 {
                    Text("\(ends.count)").font(.caption2.bold()).padding(3).background(.red, in: Circle()).foregroundStyle(.white)
                        .offset(x: 14, y: -14)
                }
            }
            Text(ends.map(\.wireID).joined(separator: ",")).font(.caption2.monospaced()).lineLimit(1)
            Text(wire?.signal ?? cav.signal ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 2) {
                if missingTerminal { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help("No terminal") }
                if missingSeal { Image(systemName: "drop.triangle.fill").foregroundStyle(.orange).help("No wire seal") }
                if missingPlug { Image(systemName: "circle.dashed").foregroundStyle(.orange).help("Unused cavity needs a plug") }
            }
            .font(.caption2)
            .frame(height: 10)
        }
        .frame(width: 82, height: 112)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(armed != nil ? Color.accentColor : (isSelected ? .accentColor : .secondary.opacity(0.3)),
                                                                style: StrokeStyle(lineWidth: armed != nil ? 1.5 : 1, dash: armed != nil ? [4, 3] : [])))
        .contentShape(Rectangle())
        .onTapGesture { tapped(cav.label) }
        .draggable("cav:\(c.id):\(cav.label)")
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first else { return false }
            return dropped(item, on: cav.label)
        }
        .help(cavityHelp(cav, ends))
    }

    private func cavityHelp(_ cav: Cavity, _ ends: [WireEnd]) -> String {
        var parts = ["Cavity \(cav.label)"]
        if let t = cav.terminal { parts.append("Terminal \(t.mpn)") }
        if let s = cav.seal { parts.append("Seal \(s.mpn)") }
        if let p = cav.plug { parts.append("Plug \(p.mpn)") }
        parts += ends.map { "\($0) → \(otherEnd($0))" }
        return parts.joined(separator: "\n")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Label("No terminal", systemImage: "exclamationmark.circle.fill")
            Label("No seal", systemImage: "drop.triangle.fill")
            Label("Needs plug", systemImage: "circle.dashed")
            Spacer()
            Text(armed.map { "Placing \($0) — click a cavity" } ?? "Drag cavities onto each other to swap them.")
                .foregroundStyle(armed == nil ? .secondary : Color.accentColor)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
    }

    // MARK: Actions

    private func tapped(_ cavity: String) {
        let target = Endpoint.pin(connector: connectorID, cavity: cavity)
        if let end = armed {
            doc.perform("Assign \(end) to \(connectorID):\(cavity)") { $0.place(end, at: target) }
            armed = nil
        }
        selectedCavity = cavity
    }

    private func dropped(_ payload: String, on cavity: String) -> Bool {
        let parts = payload.split(separator: ":").map(String.init)
        if parts.first == "cav", parts.count == 3, parts[1] == connectorID {
            doc.perform("Swap \(connectorID):\(parts[2]) ↔ \(cavity)") { $0.swapCavities(connector: connectorID, parts[2], cavity) }
            selectedCavity = cavity
            return true
        }
        if parts.first == "end", parts.count == 3, let side = WireEnd.Side(rawValue: parts[2]) {
            let end = WireEnd(parts[1], side)
            doc.perform("Assign \(end) to \(connectorID):\(cavity)") { $0.place(end, at: .pin(connector: connectorID, cavity: cavity)) }
            selectedCavity = cavity
            armed = nil
            return true
        }
        return false
    }

    private func otherEnd(_ e: WireEnd) -> String {
        doc.harness.endpoint(of: WireEnd(e.wireID, e.side == .a ? .b : .a))?.description ?? "?"
    }

    // MARK: Side panel

    private func sidePanel(_ c: Connector) -> some View {
        VStack(spacing: 0) {
            if let label = selectedCavity, let idx = c.cavities.firstIndex(where: { $0.label == label }) {
                cavityDetail(c, idx)
                Divider()
            }
            palette(c)
        }
    }

    private func cavityDetail(_ c: Connector, _ idx: Int) -> some View {
        let cav = c.cavities[idx]
        let here = Endpoint.pin(connector: c.id, cavity: cav.label)
        let ends = doc.harness.wireEnds(at: here)
        let cavBinding = Binding<Cavity>(
            get: { doc.harness.connector(connectorID)?.cavities[safe: idx] ?? cav },
            set: { v in
                if let i = doc.harness.connectors.firstIndex(where: { $0.id == connectorID }), idx < doc.harness.connectors[i].cavities.count {
                    doc.harness.connectors[i].cavities[idx] = v
                }
            })
        return Form {
            Section("Cavity \(cav.label)") {
                CavityLabelField(doc: doc, connectorID: c.id, label: cav.label) { selectedCavity = $0 }
                TextField("Signal", text: cavBinding.signal.orEmpty)
                ForEach(ends, id: \.self) { end in
                    HStack {
                        if let w = doc.harness.wire(end.wireID) { WireDot(color: w.color).frame(width: 12, height: 12) }
                        Button("\(end.description) → \(otherEnd(end))") { doc.selection = .wire(end.wireID) }.buttonStyle(.link)
                        Spacer()
                        Button("Unassign") { doc.perform("Unassign \(end)") { $0.unassign(end) } }
                    }
                }
                if ends.isEmpty {
                    Button("New Wire from Here") {
                        var newID = ""
                        doc.perform("New Wire from \(c.id):\(cav.label)") { newID = $0.addWire(from: here) }
                        armed = WireEnd(newID, .b)
                        doc.selection = .connector(c.id)
                    }
                    .help("Creates a wire starting in this cavity; its other end waits in the palette")
                }
                PartField(title: "Terminal", part: cavBinding.terminal, category: .terminal)
                PartField(title: "Seal", part: cavBinding.seal, category: .seal)
                PartField(title: "Plug", part: cavBinding.plug, category: .cavityPlug)
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 340)
    }

    private func palette(_ c: Connector) -> some View {
        let ends = doc.harness.allWireEnds.filter { end in
            guard let e = doc.harness.endpoint(of: end) else { return false }
            if e.connectorID == c.id { return false }
            guard !filter.isEmpty else { return true }
            let w = doc.harness.wire(end.wireID)
            return [end.wireID, w?.signal ?? "", e.description].contains { $0.localizedCaseInsensitiveContains(filter) }
        }
        let unassigned = ends.filter { doc.harness.endpoint(of: $0) == .unassigned }
        let elsewhere = ends.filter { doc.harness.endpoint(of: $0) != .unassigned }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Wire ends").font(.headline)
                Spacer()
                Button { doc.addWire() ; if case let .wire(id)? = doc.selection { armed = WireEnd(id, .a); doc.selection = .connector(c.id) } } label: {
                    Label("New wire", systemImage: "plus")
                }
                .help("Adds a wire with both ends unassigned")
            }
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
            List {
                Section("Unassigned (\(unassigned.count))") { ForEach(unassigned, id: \.self, content: endRow) }
                Section("On other connectors and splices") { ForEach(elsewhere, id: \.self, content: endRow) }
            }
            .listStyle(.sidebar)
        }
        .padding(10)
    }

    private func endRow(_ end: WireEnd) -> some View {
        let w = doc.harness.wire(end.wireID)
        let isArmed = armed == end
        return HStack(spacing: 6) {
            if let w { WireDot(color: w.color).frame(width: 12, height: 12) }
            Text(end.description).font(.callout.monospaced())
            Text(w?.signal ?? "").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(doc.harness.endpoint(of: end)?.description ?? "").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isArmed ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { armed = isArmed ? nil : end }
        .draggable("end:\(end.wireID):\(end.side.rawValue)")
        .help("Click, then click a cavity, or drag onto a cavity")
    }
}

/// A wire's insulation colour with its stripe.
struct WireDot: View {
    let color: WireColor

    var body: some View {
        Circle()
            .fill(Color(hex: WireTables.iecColors[color.base] ?? "#999999"))
            .overlay {
                if let s = color.stripe {
                    Rectangle().fill(Color(hex: WireTables.iecColors[s] ?? "#999999")).frame(height: 4).rotationEffect(.degrees(-35))
                        .clipShape(Circle())
                }
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.secondary, lineWidth: 0.5))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Renames a cavity on Return ("1" → "A"); wire ends, face cavities and accepted deviations follow it.
private struct CavityLabelField: View {
    @ObservedObject var doc: HarnessDocument
    let connectorID: EntityID
    let label: String
    var renamed: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField("Label", text: $text)
            .onAppear { text = label }
            .onChange(of: label) { text = label }
            .onSubmit {
                let new = text.trimmingCharacters(in: .whitespaces)
                guard new != label else { return }
                var ok = false
                doc.perform("Rename Cavity \(label) to \(new)") { ok = $0.renameCavity(connectorID, label, to: new) }
                if ok { renamed(new) } else { text = label; NSSound.beep() }
            }
            .help("Cavity label, as printed on the housing (A, B, 30, 87a…). Press Return to rename.")
    }
}
