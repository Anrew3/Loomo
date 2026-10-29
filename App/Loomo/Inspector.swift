import CrimpCore
import PartsClient
import SwiftUI

struct InspectorView: View {
    @ObservedObject var doc: HarnessDocument
    var jump: (Pane) -> Void

    var body: some View {
        Group {
            switch doc.selection {
            case let .connector(id)?: if let b = doc.binding(\.connectors, id) { ConnectorInspector(doc: doc, connector: b, jump: jump) }
            case let .wire(id)?: if let b = doc.binding(\.wires, id) { WireInspector(doc: doc, wire: b) }
            case let .splice(id)?: if let b = doc.binding(\.splices, id) { SpliceInspector(doc: doc, splice: b) }
            case let .segment(id)?: if let b = doc.binding(\.segments, id) { SegmentInspector(doc: doc, segment: b) }
            case let .covering(id)?: if let b = doc.binding(\.coverings, id) { CoveringInspector(doc: doc, covering: b) }
            case let .node(id)?: if let b = doc.binding(\.nodes, id) { NodeInspector(node: b) }
            case let .cable(id)?: if let b = doc.binding(\.cables, id) { CableInspector(doc: doc, cable: b) }
            case let .twist(id)?: if let b = doc.binding(\.twists, id) { TwistInspector(doc: doc, twist: b) }
            case let .label(id)?: if let b = doc.binding(\.labels, id) { LabelInspector(doc: doc, label: b) }
            case let .annotation(id)?: if let b = doc.binding(\.annotations, id) { AnnotationInspector(annotation: b) }
            case nil: HarnessSummary(doc: doc, jump: jump)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HarnessSummary: View {
    @ObservedObject var doc: HarnessDocument
    var jump: (Pane) -> Void

    var body: some View {
        let h = doc.harness, a = doc.analysis
        let errors = a.issues.filter { $0.severity == .error }.count
        let warnings = a.issues.filter { $0.severity == .warning }.count
        let total = a.routes.values.compactMap(\.lengthMM).reduce(0, +)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        IconTile(systemName: "point.3.connected.trianglepath.dotted", size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Harness name", text: $doc.harness.name)
                                .textFieldStyle(.plain)
                                .font(.title3.weight(.semibold))
                            HStack(spacing: 4) {
                                Text("Rev").foregroundStyle(.secondary)
                                TextField("A", text: $doc.harness.revision).textFieldStyle(.plain).frame(width: 40)
                            }
                            .font(.callout)
                        }
                    }
                    Picker("Units", selection: $doc.harness.settings.units) {
                        Text("Metric").tag(UnitSystem.metric)
                        Text("Imperial").tag(UnitSystem.imperial)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(14)
                .glassCard(cornerRadius: 20)

                Text("Overview").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(title: "Connectors", value: "\(h.connectors.count)", icon: Pane.connectors.icon, tint: Pane.connectors.tint) { jump(.connectors) }
                    StatTile(title: "Wires", value: "\(h.wires.count)", icon: Pane.wires.icon, tint: Pane.wires.tint) { jump(.wires) }
                    StatTile(title: "Total wire", value: doc.units.format(total), icon: "ruler", tint: Pane.cutList.tint) { jump(.cutList) }
                    StatTile(title: "Splices", value: "\(h.splices.count)", icon: Pane.splices.icon, tint: Pane.splices.tint) { jump(.splices) }
                    StatTile(title: "BOM lines", value: "\(a.bom.count)", icon: Pane.bom.icon, tint: Pane.bom.tint) { jump(.bom) }
                    StatTile(title: "Coverings", value: "\(h.coverings.count)", icon: Pane.coverings.icon, tint: Pane.coverings.tint) { jump(.coverings) }
                }

                let diameters = ChartData.bundleDiameters(h, analysis: a)
                if !diameters.isEmpty {
                    BarChartCard(title: "Bundle diameter", bars: diameters, format: { String(format: "Ø%.1f mm", $0) }, maxBars: 6)
                }

                HealthCard(errors: errors, warnings: warnings, accepted: a.issues.filter { $0.acceptedReason != nil }.count) { jump(.issues) }
                    .padding(-10)
                    .padding(.vertical, 10)

                Label("Click anything on the drawing to edit it here.", systemImage: "cursorarrow.click.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}

// MARK: - Connector

private struct ConnectorInspector: View {
    @ObservedObject var doc: HarnessDocument
    @EnvironmentObject var library: LibraryStore
    @Binding var connector: Connector
    var jump: (Pane) -> Void
    @State private var newID = ""
    @State private var refreshing = false
    @State private var refreshSummary: String?

    var body: some View {
        let used = Set(doc.harness.wires.flatMap { [$0.from, $0.to] }.compactMap { e -> String? in
            if case let .pin(c, cav) = e, c == connector.id { return cav }
            return nil
        })
        Form {
            Section {
                HStack {
                    Spacer()
                    if let data = connector.imagePNG, let img = NSImage(data: data) {
                        Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 150, maxHeight: 150)
                    } else if let url = connector.part.flatMap(LibraryStore.shared.photoURL) {
                        PartPhoto(url: url, size: 150)
                    }
                    Spacer()
                }
                if connector.imagePNG == nil, let from = connector.part?.dataSources?["imageURL"] {
                    HStack(spacing: 5) {
                        Spacer()
                        SourceIcons(sources: ["imageURL": from])
                        Text("Photo from \(PartsProvider.title(of: from))").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                HStack {
                    Button(connector.imagePNG == nil ? "Use My Own Picture…" : "Change Picture…") { doc.chooseConnectorPicture(connector.id) }
                    if connector.imagePNG != nil {
                        Button("Crop…") { doc.cropTarget = CropTarget(connectorID: connector.id) }
                        Button("Use Part Photo") { connector.imagePNG = nil }
                    }
                }
                .controlSize(.small)
            }
            if !connector.kind.isLooseTerminal {
                Section("Mating face") {
                    ConnectorFaceView(doc: doc, connectorID: connector.id, showLegend: false, maxScale: 1)
                        .frame(height: 150)
                    HStack {
                        Button("Edit Face…") { doc.faceEditor = FaceEditTarget(id: connector.id) }
                        Button("Export SVG…") { doc.exportFaceSVG(connector.id) }
                    }
                }
            }
            Section("Connector") {
                TextField("Designator", text: $newID)
                    .onAppear { newID = connector.id }
                    .onChange(of: connector.id) { newID = connector.id }
                    .onSubmit { rename(to: newID) }
                TextField("Name", text: $connector.name)
                Picker("Kind", selection: $connector.kind) {
                    ForEach(ConnectorKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                PartField(title: connector.kind.isLooseTerminal ? "Terminal" : "Housing", part: $connector.part,
                          category: connector.kind.isLooseTerminal ? .terminal : .connector)
                if let p = connector.part, let cfg = library.library.entry(for: p), !cfg.related.isEmpty {
                    Button("Apply Design Configuration (\(cfg.related.count) related parts)") {
                        doc.perform("Apply \(p.mpn) Configuration") { h in
                            if let i = h.connectors.firstIndex(where: { $0.id == connector.id }) { h.connectors[i].apply(cfg, usedCavities: used) }
                        }
                    }
                }
                Picker("Gender", selection: $connector.gender) {
                    ForEach(Gender.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("Individually sealed cavities", isOn: $connector.sealed)
                Picker("Mated in line with", selection: Binding(get: { connector.mate ?? "" }, set: { new in
                    let id = connector.id
                    doc.perform(new.isEmpty ? "Unmate \(id)" : "Mate \(id) and \(new)") { $0.setMate(id, new.isEmpty ? nil : new) }
                })) {
                    Text("Nothing").tag("")
                    ForEach(doc.harness.connectors.filter { $0.id != connector.id && !$0.kind.isLooseTerminal }) { Text($0.id).tag($0.id) }
                }
                Stepper("Cavities: \(connector.cavities.count)", value: cavityCount, in: 1...300)
                if let n = connector.part?.positionCount, n != connector.cavities.count {
                    Label("Part data says \(n) positions", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if connector.part != nil {
                    Button {
                        refreshing = true
                        Task {
                            refreshSummary = await doc.refreshPartData(connectorID: connector.id)
                            refreshing = false
                        }
                    } label: {
                        if refreshing { ProgressView().controlSize(.small) } else { Label("Refresh from Distributors", systemImage: "arrow.clockwise") }
                    }
                    .disabled(refreshing)
                    .help("Re-read photo, cavity count, rows, pitch and gender for this part")
                }
                Button("Open Pinout Editor") { jump(.connectors) }.buttonStyle(.link)
            }
            Section("Lengths") {
                LengthField("Insertion depth", mm: $connector.insertionDepthMM, units: doc.units)
                LengthField("Backshell entry", mm: $connector.backshellEntryMM, units: doc.units)
                if connector.kind == .pigtail {
                    LengthField("Pigtail lead length", mm: $connector.leadLengthMM.orZero, units: doc.units)
                }
            }
            Section("Fill every cavity") {
                PartField(title: "Terminal", part: bulk(\.terminal), category: .terminal)
                if connector.sealed {
                    PartField(title: "Seal", part: bulk(\.seal), category: .seal)
                    PartField(title: "Plug (unused only)", part: Binding(get: { connector.cavities.first { $0.plug != nil }?.plug }, set: { p in
                        for i in connector.cavities.indices where !used.contains(connector.cavities[i].label) { connector.cavities[i].plug = p }
                    }), category: .cavityPlug)
                }
                Button("Import Pin List (CSV)…") { doc.importPinList(into: connector.id) }
            }
            if connector.kind.isBox || !connector.boxItems.isEmpty {
                Section("Fuses and relays") {
                    ForEach($connector.boxItems) { $item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                TextField("ID", text: $item.id).frame(width: 44)
                                Picker("", selection: $item.kind) {
                                    ForEach(BoxItemKind.allCases, id: \.self) { Text($0.title).tag($0) }
                                }
                                .labelsHidden().frame(width: 120)
                                TextField("Rating", text: $item.rating.orEmpty).frame(width: 70)
                                Spacer()
                                Button { connector.boxItems.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                            HStack {
                                TextField("Cavities (e.g. 1, 2)", text: Binding(
                                    get: { item.cavities.joined(separator: ", ") },
                                    set: { item.cavities = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                                    .font(.caption)
                                PartField(title: "", part: $item.part, category: .any)
                            }
                        }
                    }
                    HStack {
                        Button("Add Fuse") {
                            let n = (connector.boxItems.filter { $0.kind == .fuse }.count) + 1
                            connector.boxItems.append(BoxItem(id: "F\(n)", kind: .fuse))
                        }
                        Button("Add Relay") {
                            let n = (connector.boxItems.filter { $0.kind == .relay }.count) + 1
                            connector.boxItems.append(BoxItem(id: "R\(n)", kind: .relay))
                        }
                    }
                    Text("Fuses and jumpers join the cavities they span, so those wires share a net. Each item is its own BOM line.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Accessories") {
                ForEach(connector.accessories.indices, id: \.self) { i in
                    HStack {
                        Picker("", selection: $connector.accessories[i].kind) {
                            ForEach(Array(Set(AccessoryKinds.all + [connector.accessories[i].kind])).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 110)
                        Text(connector.accessories[i].part.mpn).font(.caption)
                        Spacer()
                        Stepper("×\(connector.accessories[i].quantity)", value: $connector.accessories[i].quantity, in: 1...20)
                        Button { connector.accessories.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                PartField(title: "Add accessory", part: Binding(get: { nil }, set: { p in
                    if let p { connector.accessories.append(Accessory(kind: Self.guessKind(p), part: p)) }
                }), category: .accessory)
                Text("TPA, CPA, wire locks, lids and other pieces each get their own BOM type; set the quantity per connector.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notes") {
                TextField("Notes", text: $connector.notes, axis: .vertical)
            }
        }
        .alert("Part data refreshed", isPresented: summaryShown) {
            Button("OK") { refreshSummary = nil }
        } message: { Text(refreshSummary ?? "") }
    }

    /// An accessory type from the part's description ("Lid lock", "TPA"…), else Accessory.
    static func guessKind(_ p: PartRef) -> String {
        let text = ((p.description ?? "") + " " + p.mpn).lowercased()
        let ordered = AccessoryKinds.all.sorted { $0.count > $1.count }
        return ordered.first { text.contains($0.lowercased()) } ?? "Accessory"
    }

    private var summaryShown: Binding<Bool> {
        Binding(get: { refreshSummary != nil }, set: { if !$0 { refreshSummary = nil } })
    }

    private func rename(to raw: String) {
        let new = raw.trimmingCharacters(in: .whitespaces)
        let old = connector.id
        guard !new.isEmpty, new != old, doc.harness.connector(new) == nil else { newID = old; return }
        doc.perform("Rename \(old) to \(new)") { $0.renameConnector(old, to: new) }
        doc.selection = .connector(new)
    }

    private var cavityCount: Binding<Int> {
        Binding(get: { connector.cavities.count }, set: { n in
            if n > connector.cavities.count {
                connector.cavities += (connector.cavities.count + 1...n).map { Cavity(label: String($0)) }
            } else {
                connector.cavities.removeLast(connector.cavities.count - n)
            }
        })
    }

    private func bulk(_ kp: WritableKeyPath<Cavity, PartRef?>) -> Binding<PartRef?> {
        Binding(get: { connector.cavities.first?[keyPath: kp] }, set: { p in
            for i in connector.cavities.indices { connector.cavities[i][keyPath: kp] = p }
        })
    }
}

// MARK: - Wire

private struct WireInspector: View {
    @ObservedObject var doc: HarnessDocument
    @Binding var wire: Wire

    static let awgSizes = [30, 28, 26, 24, 22, 20, 18, 16, 14, 12, 10, 8, 6, 4]
    static let metricSizes = [0.13, 0.22, 0.35, 0.5, 0.75, 1.0, 1.5, 2.5, 4, 6, 10, 16, 25]
    static let colors = WireTables.colorOrder

    var body: some View {
        let route = doc.analysis.routes[wire.id]
        let u = doc.units
        Form {
            Section("Wire \(wire.id)") {
                TextField("Signal", text: $wire.signal.orEmpty)
                Picker("From", selection: $wire.from) { endpointOptions }
                Picker("To", selection: $wire.to) { endpointOptions }
                Picker("Role", selection: $wire.role) {
                    ForEach(WireRole.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Cable", selection: $wire.cableID) {
                    Text("None").tag(EntityID?.none)
                    ForEach(doc.harness.cables) { Text("\($0.id) \($0.name)").tag(EntityID?.some($0.id)) }
                }
            }
            Section("Specification") {
                Picker("Size", selection: sizeBinding) {
                    Section("AWG") { ForEach(Self.awgSizes, id: \.self) { Text("\($0) AWG").tag("awg\($0)") } }
                    Section("Metric") { ForEach(Self.metricSizes, id: \.self) { Text(String(format: "%g mm²", $0)).tag("mm\($0)") } }
                    if wire.size.customLabel != nil { Text(wire.size.description).tag("custom") }
                }
                TextField("Custom size label", text: $wire.size.customLabel.orEmpty)
                Picker("Insulation", selection: $wire.insulation) {
                    ForEach(["TXL", "GXL", "SXL", "PTFE", "ETFE", "XLPE", "PVC", "Silicone"], id: \.self) { Text($0).tag($0) }
                }
                Picker("Base colour", selection: $wire.color.base) { ForEach(Self.colors, id: \.self) { Text(colorLabel($0)).tag($0) } }
                Picker("Stripe", selection: $wire.color.stripe) {
                    Text("None").tag(String?.none)
                    ForEach(Self.colors, id: \.self) { Text(colorLabel($0)).tag(String?.some($0)) }
                }
                LengthField("Outer Ø", mm: $wire.outerDiameterMM, units: .metric, decimals: 2)
                PartField(title: "Wire part", part: $wire.part, category: .wire)
                TextField("Marker text", text: $wire.markerText.orEmpty)
            }
            Section("Length") {
                LabeledContent("Route", value: route?.segmentIDs.joined(separator: " → ") ?? "none")
                LabeledContent("Bundle path", value: u.format(route?.pathLengthMM))
                LabeledContent("End A allowance", value: u.format(route?.endAllowanceAMM, decimals: 1))
                LabeledContent("End B allowance", value: u.format(route?.endAllowanceBMM, decimals: 1))
                if let t = route?.twistTakeUpMM, t > 0 { LabeledContent("Twist take-up", value: u.format(t, decimals: 1)) }
                LengthField("Extra length", mm: $wire.extraLengthMM, units: u)
                Toggle("Override length", isOn: Binding(
                    get: { wire.lengthOverrideMM != nil },
                    set: { wire.lengthOverrideMM = $0 ? (route?.lengthMM ?? 1000) : nil }))
                if wire.lengthOverrideMM != nil { LengthField("Length", mm: $wire.lengthOverrideMM.orZero, units: u) }
                LabeledContent("Manufacturing length", value: u.format(route?.lengthMM)).bold()
            }
        }
    }

    @ViewBuilder private var endpointOptions: some View {
        ForEach(doc.allEndpoints, id: \.self) { Text($0.description).tag($0) }
    }

    private var sizeBinding: Binding<String> {
        Binding(get: {
            if wire.size.customLabel != nil { return "custom" }
            return wire.size.awg.map { "awg\($0)" } ?? "mm\(wire.size.crossSectionMM2)"
        }, set: { tag in
            if tag.hasPrefix("awg"), let n = Int(tag.dropFirst(3)) { wire.size = .awg(n) }
            else if tag.hasPrefix("mm"), let v = Double(tag.dropFirst(2)) { wire.size = WireSize(mm2: v) }
            else { return }
            wire.outerDiameterMM = WireTables.defaultOD(for: wire.size, insulation: wire.insulation)
        })
    }
}

// MARK: - Others

private struct SpliceInspector: View {
    @ObservedObject var doc: HarnessDocument
    @Binding var splice: Splice

    var body: some View {
        Form {
            Section("Splice \(splice.id)") {
                Picker("Kind", selection: $splice.kind) {
                    ForEach(SpliceKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if splice.kind == .inlineDiode || splice.kind == .inlineResistor {
                    TextField("Value", text: $splice.value.orEmpty)
                }
                PartField(title: "Part", part: $splice.part, category: .splice)
                PartField(title: "Heat shrink", part: $splice.heatShrink, category: .heatShrink)
            }
            Section("Wires") {
                ForEach(doc.harness.wireEnds(at: .splice(splice.id)), id: \.self) { end in
                    Button(end.description) { doc.selection = .wire(end.wireID) }.buttonStyle(.link)
                }
            }
        }
    }
}

private struct SegmentInspector: View {
    @ObservedObject var doc: HarnessDocument
    @Binding var segment: Segment

    var body: some View {
        let a = doc.analysis
        let wires = a.segmentWires[segment.id] ?? []
        Form {
            Section("Segment \(segment.id)") {
                LabeledContent("Between", value: "\(segment.nodeA) – \(segment.nodeB)")
                LengthField("Length", mm: $segment.lengthMM, units: doc.units)
                LabeledContent("Bundle Ø", value: String(format: "%.1f mm", a.bundleDiameterMM[segment.id] ?? 0))
            }
            Section("Bundle contents (\(wires.count))") {
                ForEach(wires, id: \.self) { wid in
                    if let w = doc.harness.wire(wid) {
                        Button { doc.selection = .wire(wid) } label: {
                            HStack {
                                WireDot(color: w.color).frame(width: 11, height: 11)
                                Text(wid).monospaced()
                                Text(w.signal ?? "").foregroundStyle(.secondary)
                                Spacer()
                                Text(w.cableID ?? "").font(.caption)
                                Text(w.size.description).font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("Coverings") {
                ForEach(doc.harness.coverings.filter { $0.segmentIDs.contains(segment.id) }) { c in
                    Button("\(c.id) · \(c.kind.title)") { doc.selection = .covering(c.id) }.buttonStyle(.link)
                }
                Menu("Add covering here") {
                    ForEach(CoveringKind.allCases, id: \.self) { k in Button(k.title) { doc.addCovering(k, segments: [segment.id]) } }
                }
                Button("Add label at middle") { doc.addLabel(on: segment.id, offsetMM: (segment.lengthMM / 2).rounded()) }
            }
        }
    }
}

private struct NodeInspector: View {
    @Binding var node: TopologyNode

    var body: some View {
        Form {
            Section("Node \(node.id)") {
                TextField("Label", text: $node.label)
                LabeledContent("Kind", value: node.kind.rawValue)
                NumberField("X", value: $node.position.x)
                NumberField("Y", value: $node.position.y)
                if node.kind == .clip || node.kind == .breakout {
                    PartField(title: "Clip / grommet", part: $node.part, category: .accessory)
                }
            }
        }
    }
}

private struct CoveringInspector: View {
    @ObservedObject var doc: HarnessDocument
    @Binding var covering: Covering

    var body: some View {
        Form {
            Section("Covering \(covering.id)") {
                Picker("Kind", selection: $covering.kind) {
                    ForEach(CoveringKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: covering.kind) { if covering.kind == .tape && covering.tape == nil { covering.tape = TapeWrap() } }
                PartField(title: "Part", part: $covering.part, category: covering.kind == .tape ? .tape : (covering.kind == .heatShrink ? .heatShrink : .covering))
                    .onChange(of: covering.part) {
                        // Sleeving and heat shrink from the catalog carry the bundle range they fit.
                        guard covering.kind != .tape, let p = covering.part else { return }
                        if let hi = p.maxInsulationODMM { covering.innerDiameterMM = hi }
                        if let lo = p.minInsulationODMM { covering.minDiameterMM = lo }
                    }
                ColorPicker("Drawing colour", selection: Binding(
                    get: { Color(hex: covering.colorHex) },
                    set: { covering.colorHex = NSColor($0).usingColorSpace(.sRGB).map { String(format: "#%02X%02X%02X", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255)) } ?? covering.colorHex }))
            }
            if covering.kind == .tape {
                Section("Tape wrap") {
                    Picker("Style", selection: tape.style) {
                        Text("Half-lap").tag(TapeStyle.halfLap)
                        Text("Spiral").tag(TapeStyle.spiral)
                        Text("Spot").tag(TapeStyle.spot)
                    }
                    NumberField("Tape width (mm)", value: tape.widthMM)
                    if covering.tape?.style != .halfLap {
                        NumberField(covering.tape?.style == .spot ? "Spot spacing (mm)" : "Pitch (mm)", value: tape.pitchMM)
                    }
                    if covering.tape?.style == .spot {
                        Stepper("Turns per spot: \(covering.tape?.turnsPerSpot ?? 3)", value: tape.turnsPerSpot, in: 1...10)
                    }
                }
            } else {
                Section("Size (checked against the bundle)") {
                    NumberField("Inner Ø (mm)", value: $covering.innerDiameterMM.orZero)
                    NumberField("Minimum Ø (mm)", value: $covering.minDiameterMM.orZero)
                }
            }
            Section("Applied to segments") {
                ForEach(doc.harness.segments) { seg in
                    Toggle(isOn: Binding(
                        get: { covering.segmentIDs.contains(seg.id) },
                        set: { on in if on { covering.segmentIDs.append(seg.id) } else { covering.segmentIDs.removeAll { $0 == seg.id } } })) {
                        Text("\(seg.id)  \(seg.nodeA)–\(seg.nodeB)  \(doc.units.format(seg.lengthMM))  Ø\(String(format: "%.1f", doc.analysis.bundleDiameterMM[seg.id] ?? 0))")
                    }
                }
            }
            Section {
                LabeledContent("Material required", value: doc.units.format(HarnessAnalysis.coveringQuantityMM(covering, in: doc.harness, bundle: doc.analysis.bundleDiameterMM)))
            }
        }
    }

    private var tape: Binding<TapeWrap> {
        Binding(get: { covering.tape ?? TapeWrap() }, set: { covering.tape = $0 })
    }
}

private struct CableInspector: View {
    @ObservedObject var doc: HarnessDocument
    @Binding var cable: Cable

    var body: some View {
        Form {
            Section("Cable \(cable.id)") {
                TextField("Name", text: $cable.name)
                PartField(title: "Cable part", part: $cable.part, category: .wire)
                Toggle("Shielded", isOn: $cable.shielded)
                NumberField("Jacket Ø (mm)", value: $cable.jacketODMM)
                LengthField("Jacket strip per end", mm: $cable.jacketStripMM, units: doc.units)
                LabeledContent("Jacket length", value: doc.units.format(HarnessAnalysis.cableJacketLength(cable, doc.harness, doc.analysis.routes)))
            }
            Section("Cores") {
                ForEach(doc.harness.wires.filter { $0.cableID == cable.id }) { w in
                    Button { doc.selection = .wire(w.id) } label: {
                        HStack { WireDot(color: w.color).frame(width: 11, height: 11); Text(w.id); Text(w.role.rawValue).foregroundStyle(.secondary) }
                    }.buttonStyle(.plain)
                }
                if cable.shielded {
                    Button("Add Drain Wire") {
                        doc.perform("Add Drain Wire") { h in
                            let id = h.nextID(prefix: "W")
                            h.wires.append(Wire(id: id, signal: "SHIELD", size: .awg(22), color: WireColor("GY"), insulation: "Bare",
                                                outerDiameterMM: 0.8, from: .unassigned, to: .unassigned, cableID: cable.id, role: .drain))
                        }
                    }
                }
            }
            Section { Button("Dissolve Cable", role: .destructive) { doc.perform("Dissolve Cable") { $0.dissolveCable(cable.id) }; doc.selection = nil } }
        }
    }
}

private struct TwistInspector: View {
    @ObservedObject var doc: HarnessDocument
    @Binding var twist: Twist

    var body: some View {
        Form {
            Section("Twist \(twist.id)") {
                LengthField("Lay length (one twist)", mm: $twist.layLengthMM, units: doc.units, decimals: 1)
                LabeledContent("Twists per metre", value: twist.layLengthMM > 0 ? String(format: "%.0f", 1000 / twist.layLengthMM) : "—")
                ForEach(twist.wireIDs, id: \.self) { w in Button(w) { doc.selection = .wire(w) }.buttonStyle(.link) }
            }
            Section { Button("Untwist", role: .destructive) { doc.perform("Untwist") { $0.twists.removeAll { $0.id == twist.id } }; doc.selection = nil } }
        }
    }
}

private struct LabelInspector: View {
    @ObservedObject var doc: HarnessDocument
    @Binding var label: BundleLabel

    var body: some View {
        Form {
            Section("Label \(label.id)") {
                Toggle("Sync text from item", isOn: Binding(get: { label.text == nil }, set: { label.text = $0 ? nil : HarnessAnalysis.labelText(label, doc.harness) }))
                if label.text != nil { TextField("Text", text: $label.text.orEmpty) }
                else { LabeledContent("Text", value: HarnessAnalysis.labelText(label, doc.harness)) }
                if case let .segment(sid, off) = label.placement {
                    LabeledContent("Segment", value: sid)
                    LengthField("Offset from \(doc.harness.segment(sid)?.nodeA ?? "A")", mm: Binding(
                        get: { off }, set: { label.placement = .segment(sid, offsetMM: $0) }), units: doc.units)
                }
                PartField(title: "Label part", part: $label.part, category: .accessory)
            }
        }
    }
}

private struct AnnotationInspector: View {
    @Binding var annotation: Annotation

    var body: some View {
        Form {
            Section(annotation.kind == .sticky ? "Sticky note" : annotation.kind.rawValue.capitalized) {
                if annotation.kind != .image { TextField(annotation.kind == .frame ? "Title" : "Text", text: $annotation.text, axis: .vertical) }
                if annotation.kind == .frame {
                    Toggle("Dashed (optional or variant)", isOn: Binding(get: { annotation.dashed ?? false }, set: { annotation.dashed = $0 ? true : nil }))
                }
                NumberField("X", value: $annotation.x)
                NumberField("Y", value: $annotation.y)
                NumberField("Width", value: $annotation.width)
                NumberField("Height", value: $annotation.height)
                ColorPicker("Colour", selection: Binding(
                    get: { Color(hex: annotation.colorHex) },
                    set: { annotation.colorHex = NSColor($0).usingColorSpace(.sRGB).map { String(format: "#%02X%02X%02X", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255)) } ?? annotation.colorHex }))
                HStack {
                    Button("Send Backward") { annotation.z -= 1 }
                    Button("Bring Forward") { annotation.z += 1 }
                }
            }
        }
    }
}

// MARK: - Shared controls

struct NumberField: View {
    let title: String
    @Binding var value: Double

    init(_ title: String, value: Binding<Double>) {
        self.title = title
        _value = value
    }

    var body: some View {
        TextField(title, value: $value, format: .number.precision(.fractionLength(0...3)))
            .multilineTextAlignment(.trailing)
    }
}

/// A length stored in mm, shown and typed in the harness's units.
struct LengthField: View {
    let title: String
    @Binding var mm: Double
    let units: UnitSystem
    var decimals = 0

    init(_ title: String, mm: Binding<Double>, units: UnitSystem, decimals: Int = 0) {
        self.title = title
        _mm = mm
        self.units = units
        self.decimals = decimals
    }

    /// Typed value, committed to the model on Return or when focus leaves (not per keystroke: every change
    /// re-analyses the whole harness and is an undo step).
    @State private var text = ""
    @FocusState private var focused: Bool

    private var format: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...(units == .imperial ? 3 : max(decimals, 1))))
    }

    var body: some View {
        TextField("\(title) (\(units.symbol))", text: $text)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onAppear { text = units.fromMM(mm).formatted(format) }
            .onChange(of: mm) { if !focused { text = units.fromMM(mm).formatted(format) } }
            .onChange(of: units) { text = units.fromMM(mm).formatted(format) }
            .onSubmit { commit() }
            .onChange(of: focused) { if !focused { commit() } }
    }

    private func commit() {
        if let v = try? Double(text, format: format), units.toMM(v) != mm { mm = units.toMM(v) }
        text = units.fromMM(mm).formatted(format)
    }
}

extension Binding where Value == String? {
    var orEmpty: Binding<String> {
        Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

extension Binding where Value == Double? {
    var orZero: Binding<Double> {
        Binding<Double>(get: { wrappedValue ?? 0 }, set: { wrappedValue = $0 == 0 ? nil : $0 })
    }
}
