import CrimpCore
import CrimpOutputs
import PDFKit
import SwiftUI

struct BOMView: View {
    @ObservedObject var doc: HarnessDocument
    @State private var sortOrder = [KeyPathComparator(\BOMLine.category)]
    @State private var selected: BOMLine.ID?
    @State private var showExcluded = false
    @State private var refreshing = false
    @State private var refreshSummary: String?

    var body: some View {
        let bom = doc.analysis.bom.sorted(using: sortOrder)
        let u = doc.units
        VStack(spacing: 0) {
            ChartStrip(key: "bom") {
                let cost = ChartData.costByCategory(doc.analysis.bom)
                if !cost.isEmpty {
                    BarChartCard(title: "Cost by category", bars: cost, format: { $0.formatted(.currency(code: "USD")) }, maxBars: 6)
                        .frame(maxWidth: 460)
                }
                BarChartCard(title: "Pieces by category", bars: ChartData.partsByCategory(doc.analysis.bom),
                             format: { String(format: "%g", $0) }, maxBars: 6)
                    .frame(maxWidth: 460)
            }
            Table(bom, selection: $selected, sortOrder: $sortOrder) {
                TableColumn("Category", value: \.category).width(85)
                TableColumn("Internal PN", value: \.internalPN).width(90)
                TableColumn("MPN", value: \.mpn)
                TableColumn("Manufacturer", value: \.manufacturer)
                TableColumn("Description", value: \.description)
                TableColumn("Qty", value: \.quantity) { l in
                    HStack(spacing: 2) {
                        Text(l.unit == .mm ? u.format(l.quantity) : String(format: "%g", l.quantity)).monospacedDigit()
                        if l.isOverridden { Image(systemName: "pencil").help("Overridden; computed \(String(format: "%g", l.computedQuantity))") }
                    }
                }.width(90)
                TableColumn("References") { Text($0.references.joined(separator: ", ")) }
                TableColumn("Alternates") { Text($0.alternates.joined(separator: ", ")) }
                TableColumn("Ext. price") { Text($0.extendedPrice.map { String(format: "$%.2f", $0) } ?? "") }.width(70)
            }
            Divider()
            HStack(spacing: 8) {
                let total = bom.compactMap(\.extendedPrice).reduce(0, +)
                Text("\(bom.count) lines · priced total $\(String(format: "%.2f", total))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let id = selected, let line = bom.first(where: { $0.id == id }) {
                    OverrideField(line: line, doc: doc)
                    Button("Exclude") { doc.perform("Exclude BOM Line") { $0.bomExcluded.append(id) }; selected = nil }
                }
                if !doc.harness.bomExcluded.isEmpty {
                    Button("Restore \(doc.harness.bomExcluded.count) Excluded") { doc.perform("Restore BOM Lines") { $0.bomExcluded.removeAll() } }
                }
                Button("Add Line…") { addManualLine() }
                Button {
                    refreshing = true
                    Task {
                        refreshSummary = await doc.refreshPrices()
                        refreshing = false
                    }
                } label: {
                    if refreshing { ProgressView().controlSize(.small) } else { Label("Refresh Prices", systemImage: "dollarsign.arrow.circlepath") }
                }
                .disabled(refreshing)
                .help("Fetch current distributor prices for every part number (TrustedParts in batches, else OEMsecrets)")
                Button("Export Excel…") { doc.exportExcel() }
            }
            .padding(8)
        }
        .alert("Prices refreshed", isPresented: summaryAlert) {
            Button("OK") { refreshSummary = nil }
        } message: { Text(refreshSummary ?? "") }
    }

    private var summaryAlert: Binding<Bool> {
        Binding(get: { refreshSummary != nil }, set: { if !$0 { refreshSummary = nil } })
    }

    private func addManualLine() {
        let alert = NSAlert()
        alert.messageText = "Add a BOM line"
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        stack.orientation = .vertical
        let mpn = NSTextField(string: ""); mpn.placeholderString = "MPN"
        let desc = NSTextField(string: ""); desc.placeholderString = "Description (e.g. cable tie)"
        let qty = NSTextField(string: "1"); qty.placeholderString = "Quantity"
        [mpn, desc, qty].forEach(stack.addArrangedSubview)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !(mpn.stringValue + desc.stringValue).isEmpty else { return }
        doc.perform("Add BOM Line") {
            $0.bomExtraLines.append(ExtraBOMLine(part: PartRef(mpn: mpn.stringValue.isEmpty ? "—" : mpn.stringValue, manufacturer: "",
                                                               description: desc.stringValue), quantity: Double(qty.stringValue) ?? 1))
        }
    }
}

private struct OverrideField: View {
    let line: BOMLine
    @ObservedObject var doc: HarnessDocument
    @State private var value: Double = 0

    var body: some View {
        HStack(spacing: 4) {
            Text("Qty").font(.caption)
            TextField("Qty", value: $value, format: .number).frame(width: 70)
                .onAppear { value = line.quantity }
                .onChange(of: line.id) { value = line.quantity }
                .onSubmit { doc.perform("Override Quantity") { $0.bomQuantityOverrides[line.id] = value } }
            if line.isOverridden {
                Button("Reset") { doc.perform("Reset Quantity") { $0.bomQuantityOverrides[line.id] = nil } }
            }
        }
    }
}

struct CutListView: View {
    @ObservedObject var doc: HarnessDocument

    var body: some View {
        let u = doc.units
        VStack(spacing: 0) {
            ChartStrip(key: "cutList") {
                BarChartCard(title: "Wire to cut, by size", bars: ChartData.wireLengthBySize(doc.harness, analysis: doc.analysis),
                             format: { u.format($0) }, maxBars: 6)
                    .frame(maxWidth: 460)
            }
            cutTable(u)
        }
    }

    private func cutTable(_ u: UnitSystem) -> some View {
        Table(doc.analysis.cutList) {
            TableColumn("Wire", value: \.wireID).width(48)
            TableColumn("Kind", value: \.kind).width(70)
            TableColumn("Size", value: \.size).width(65)
            TableColumn("Colour", value: \.color).width(60)
            TableColumn("Cut") { Text(u.format($0.cutLengthMM)).monospacedDigit().bold() }.width(70)
            TableColumn("End A") { r in Text(r.endA + (r.stripA.map { "  ✂︎\(u.format($0, decimals: 1))" } ?? "")) }
            TableColumn("Terminal / seal A") { Text("\($0.terminalA) / \($0.sealA)") }
            TableColumn("End B") { r in Text(r.endB + (r.stripB.map { "  ✂︎\(u.format($0, decimals: 1))" } ?? "")) }
            TableColumn("Terminal / seal B") { Text("\($0.terminalB) / \($0.sealB)") }
            TableColumn("Marker", value: \.marker).width(70)
        }
    }
}

/// Connections, RapidHarness-style but browsable: pick a connector or splice on the left and see where every
/// cavity goes, with the mating face beside the table. Destinations are links to the other end.
struct ConnectorTablesView: View {
    @ObservedObject var doc: HarnessDocument
    @State private var current: EntityID?
    @State private var hoveredCavity: String?
    @AppStorage("connections.showAll") private var showAll = false

    var body: some View {
        let a = doc.analysis
        let tables = a.connectorTables + a.spliceTables
        HStack(spacing: 0) {
            List(selection: $current) {
                Section("Connectors") {
                    ForEach(a.connectorTables) { t in row(t, isSplice: false).tag(t.connectorID) }
                }
                if !a.spliceTables.isEmpty {
                    Section("Splices") {
                        ForEach(a.spliceTables) { t in row(t, isSplice: true).tag(t.connectorID) }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $showAll) {
                        Text("One at a Time").tag(false)
                        Text("All").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Toggle("Show tables on the drawing", isOn: Binding(get: { doc.harness.settings.showConnectionTables ?? false },
                                                                     set: { doc.harness.settings.showConnectionTables = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if showAll {
                            ForEach(tables) { card($0) }
                        } else if let id = current ?? tables.first?.connectorID, let t = tables.first(where: { $0.connectorID == id }) {
                            card(t)
                        } else {
                            ContentUnavailableView("No connections yet", systemImage: "tablecells",
                                                   description: Text("Place connectors and wires; their tables appear here."))
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onAppear { syncFromSelection() }
        .onChange(of: doc.selection) { syncFromSelection() }
        .onChange(of: current) {
            guard let id = current else { return }
            if doc.harness.connector(id) != nil, doc.selection != .connector(id) { doc.selection = .connector(id) }
            if doc.harness.splice(id) != nil, doc.selection != .splice(id) { doc.selection = .splice(id) }
        }
    }

    private func syncFromSelection() {
        switch doc.selection {
        case let .connector(id)?, let .splice(id)?: if current != id { current = id }
        default: break
        }
    }

    private func row(_ t: ConnectorTable, isSplice: Bool) -> some View {
        let used = t.rows.filter { !$0.wireID.isEmpty }
        let c = doc.harness.connector(t.connectorID)
        return HStack(spacing: 8) {
            Image(systemName: isSplice ? "arrow.triangle.merge" : (c?.kind.isBox == true ? "bolt.square" : (c?.mate != nil ? "link" : "powerplug")))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.connectorID).fontWeight(.semibold)
                Text(isSplice ? "\(used.count) wires" : [c?.name, c?.part?.mpn].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !isSplice {
                Text("\(Set(used.map(\.cavity)).count)/\(c?.cavities.count ?? 0)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("Cavities used")
            }
        }
    }

    @ViewBuilder
    private func card(_ t: ConnectorTable) -> some View {
        let h = doc.harness
        let c = h.connector(t.connectorID)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.connectorID).font(.title2.weight(.semibold))
                    if let c {
                        Text([c.name, c.part?.mpn, c.part?.manufacturer].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Pill(text: c.kind.title, tint: .secondary)
                            Pill(text: c.gender.rawValue.capitalized, tint: .secondary)
                            if c.sealed { Pill(text: "Sealed", tint: .secondary) }
                            if let item = doc.analysis.itemNumbers[c.id] { Pill(text: "Item \(item)", tint: .accentColor) }
                        }
                        if let m = c.mate {
                            Button { current = m } label: { Label("Mates in line with \(m)", systemImage: "link") }.buttonStyle(.link)
                        }
                        if !c.boxItems.isEmpty {
                            Text(c.boxItems.map { "\($0.id) \($0.rating ?? $0.kind.title): \($0.cavities.joined(separator: "–"))" }.joined(separator: "   "))
                                .font(.callout)
                        }
                    } else if let s = h.splice(t.connectorID) {
                        Text([s.kind.title, s.part?.mpn].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                    }
                    Button("Show on Drawing") {
                        if let c { doc.selection = .connector(c.id) } else { doc.selection = .splice(t.connectorID) }
                        NotificationCenter.default.post(name: .showDrawing, object: doc)
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
                Spacer()
                if let c, !c.kind.isLooseTerminal, c.kind != .loosePins {
                    ConnectorFaceView(doc: doc, connectorID: c.id, showLegend: false, selectedCavity: hoveredCavity, maxScale: 1.1)
                        .frame(width: 220, height: 170)
                }
            }
            connectionGrid(t, isSplice: c == nil)
        }
        .padding(16)
        .glassCard()
    }

    private func connectionGrid(_ t: ConnectorTable, isSplice: Bool) -> some View {
        let wires = Dictionary(doc.harness.wires.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                ForEach([isSplice ? "Wire" : "Pin", "Conductor", "Wire", "Size", "To", "Contact", "Seal", "Twisted with"], id: \.self) {
                    Text($0.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 6)
            ForEach(Array(t.rows.enumerated()), id: \.offset) { i, r in
                let w = wires[r.wireID]
                GridRow {
                    Text(r.cavity).fontWeight(.semibold).monospacedDigit()
                    HStack(spacing: 6) {
                        if let w { WireDot(color: w.color).frame(width: 12, height: 12) }
                        Text(r.wireID.isEmpty ? (r.destination.isEmpty ? "unused" : r.destination) : r.conductor)
                            .foregroundStyle(r.wireID.isEmpty ? .tertiary : .primary)
                    }
                    Button(r.wireID) { if let w { doc.selection = .wire(w.id) } }.buttonStyle(.link).disabled(r.wireID.isEmpty)
                    Text(r.size)
                    destination(r.wireID.isEmpty ? "" : r.destination)
                    Text(r.terminal).foregroundStyle(.secondary)
                    Text(r.seal).foregroundStyle(.secondary)
                    Text(r.twistedWith)
                }
                .font(.callout)
                .padding(.vertical, 5)
                .background(i % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                .onHover { hoveredCavity = $0 && !isSplice ? r.cavity : nil }
            }
        }
    }

    /// "C2:5" as a link that opens C2's table.
    @ViewBuilder
    private func destination(_ text: String) -> some View {
        let id = text.split(separator: ":").first.map(String.init) ?? text
        if !text.isEmpty, doc.harness.connector(id) != nil || doc.harness.splice(id) != nil {
            Button(text) { current = id }.buttonStyle(.link)
        } else {
            Text(text)
        }
    }
}

struct NetlistView: View {
    @ObservedObject var doc: HarnessDocument

    var body: some View {
        Table(doc.analysis.nets) {
            TableColumn("Net", value: \.name)
            TableColumn("Pins") { Text($0.members.joined(separator: ", ")) }
            TableColumn("Wires") { Text($0.wires.joined(separator: ", ")) }
        }
    }
}

struct LabelListView: View {
    @ObservedObject var doc: HarnessDocument

    var body: some View {
        Table(doc.analysis.labelList) {
            TableColumn("Label", value: \.id).width(70)
            TableColumn("Text", value: \.text)
            TableColumn("Location", value: \.location)
            TableColumn("Part", value: \.part)
        }
    }
}

struct ToolsView: View {
    @ObservedObject var doc: HarnessDocument

    var body: some View {
        Table(doc.analysis.toolList) {
            TableColumn("Tool", value: \.name)
            TableColumn("Kind", value: \.kind).width(100)
            TableColumn("Part number", value: \.partNumber)
            TableColumn("Used for") { Text($0.usedFor.joined(separator: "; ")) }
        }
    }
}

struct IssuesView: View {
    @ObservedObject var doc: HarnessDocument
    var jump: (Pane) -> Void
    @State private var accepting: Issue?
    @State private var reason = ""

    var body: some View {
        let issues = doc.analysis.issues
        Group {
            if issues.isEmpty {
                ContentUnavailableView("No issues", systemImage: "checkmark.seal", description: Text("Every rule check passed."))
            } else {
                List(issues) { issue in
                    Button { go(issue.subject) } label: {
                        HStack(alignment: .top) {
                            Image(systemName: issue.acceptedReason != nil ? "checkmark.seal" : icon(issue.severity))
                                .foregroundStyle(issue.acceptedReason != nil ? Color.green : color(issue.severity))
                            Text(issue.subject).bold().frame(width: 70, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.message)
                                if let r = issue.acceptedReason {
                                    Text("Accepted: \(r)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if issue.acceptedReason != nil {
                            Button("Revoke Acceptance") { revoke(issue) }
                        } else if issue.severity != .info {
                            Button("Accept as Reviewed Deviation…") { reason = ""; accepting = issue }
                        }
                        Button("Go to \(issue.subject)") { go(issue.subject) }
                    }
                }
            }
        }
        .alert("Accept this check?", isPresented: Binding(get: { accepting != nil }, set: { if !$0 { accepting = nil } })) {
            TextField("Reason", text: $reason)
            Button("Accept") { if let i = accepting { accept(i) } }
                .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(accepting?.subject ?? ""): \(accepting?.message ?? "")\n\nIt will show as accepted until the design changes this check.")
        }
    }

    private func accept(_ issue: Issue) {
        let why = reason.trimmingCharacters(in: .whitespaces)
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        doc.perform("Accept \(issue.subject)") {
            $0.acceptedIssues.append(AcceptedIssue(subject: issue.subject, message: issue.message, reason: why, date: date))
        }
    }

    private func revoke(_ issue: Issue) {
        doc.perform("Revoke Acceptance") { $0.acceptedIssues.removeAll { $0.subject == issue.subject && $0.message == issue.message } }
    }

    /// Jumps to the item: selects it and opens the page where it is edited.
    private func go(_ subject: EntityID) {
        guard let s = doc.selection(for: subject) else { return }
        doc.selection = s
        switch s {
        case .connector: jump(.connectors)
        case .wire: jump(.wires)
        case .cable, .twist: jump(.cables)
        case .splice, .segment, .node, .annotation: jump(.topology)
        case .covering: jump(.coverings)
        case .label: jump(.labels)
        }
    }

    private func icon(_ s: Issue.Severity) -> String {
        switch s { case .error: "xmark.octagon.fill"; case .warning: "exclamationmark.triangle.fill"; case .info: "info.circle" }
    }

    private func color(_ s: Issue.Severity) -> Color {
        switch s { case .error: .red; case .warning: .orange; case .info: .secondary }
    }
}

// MARK: - Print & export

struct ExportPane: View {
    @ObservedObject var doc: HarnessDocument
    @AppStorage("exportPages") private var pagesRaw = DrawingPage.allCases.map(\.rawValue).joined(separator: ",")
    @AppStorage("export.sideTables") private var sideTables = true
    @AppStorage("formboard.layout") private var boardLayout = FormboardOptions.Layout.tiled.rawValue
    @AppStorage("formboard.paper") private var boardPaper = SheetSize.letter.rawValue
    @AppStorage("formboard.portrait") private var boardPortrait = false
    @AppStorage("formboard.overlap") private var boardOverlap = 0.0
    @AppStorage("formboard.map") private var boardMap = true
    @State private var previewBoard = false

    private var boardOptions: FormboardOptions {
        var o = FormboardOptions()
        o.layout = FormboardOptions.Layout(rawValue: boardLayout) ?? .tiled
        o.paper = SheetSize(rawValue: boardPaper) ?? .letter
        o.portrait = boardPortrait
        o.overlapMM = boardOverlap
        o.assemblyMap = boardMap
        return o
    }

    private var pages: [DrawingPage] {
        let set = Set(pagesRaw.split(separator: ",").map(String.init))
        return DrawingPage.allCases.filter { set.contains($0.rawValue) }
    }

    var body: some View {
        // A plain HStack, not HSplitView: a split view with large minimum widths nested inside the window's
        // own split view could fight it over sizes until AppKit threw (the Print & Export crash).
        HStack(spacing: 0) {
            Form {
                Section("Pages") {
                    ForEach(DrawingPage.allCases) { p in
                        Toggle(p.title, isOn: Binding(
                            get: { pages.contains(p) },
                            set: { on in
                                var set = Set(pages)
                                if on { set.insert(p) } else { set.remove(p) }
                                pagesRaw = DrawingPage.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
                            }))
                    }
                }
                Section("Sheet") {
                    Picker("Size", selection: $doc.harness.titleBlock.sheetSize) {
                        ForEach(SheetSize.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("BOM, notes and legend beside the drawing", isOn: $sideTables)
                    Toggle("Connection tables on the drawing", isOn: Binding(get: { doc.harness.settings.showConnectionTables ?? false },
                                                                           set: { doc.harness.settings.showConnectionTables = $0 }))
                    Toggle("BOM item numbers on the drawing", isOn: Binding(get: { doc.harness.settings.showItemNumbers ?? false },
                                                                          set: { doc.harness.settings.showItemNumbers = $0 }))
                }
                Section("Export") {
                    Button("Drawing Set PDF…") { doc.exportPDF(pages: pages, sideTables: sideTables) }
                    Button("Excel Workbook…") { doc.exportExcel() }
                    Button("WireViz YAML…") { doc.exportWireViz() }
                    Button("Print…") { print() }
                }
                Section {
                    Picker("Print on", selection: $boardLayout) {
                        Text("Sheets joined edge to edge").tag(FormboardOptions.Layout.tiled.rawValue)
                        Text("One large sheet (plotter)").tag(FormboardOptions.Layout.singleSheet.rawValue)
                    }
                    if boardLayout == FormboardOptions.Layout.tiled.rawValue {
                        Picker("Paper", selection: $boardPaper) {
                            ForEach([SheetSize.letter, .tabloid, .a4, .a3], id: \.self) { Text($0.title).tag($0.rawValue) }
                        }
                        Toggle("Portrait", isOn: $boardPortrait)
                        Picker("Join", selection: $boardOverlap) {
                            Text("Trim and butt edges").tag(0.0)
                            Text("Overlap 10 mm to glue").tag(10.0)
                            Text("Overlap 20 mm to glue").tag(20.0)
                        }
                        Toggle("Assembly map first", isOn: $boardMap)
                    } else {
                        Text("Sized to the harness at 1:1. Sides over 200 in (the PDF limit) are split into as few panels as needed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Preview the formboard", isOn: $previewBoard)
                    Button("Formboard 1:1 PDF…") { doc.exportFormboard(boardOptions) }
                } header: {
                    Text("Formboard 1:1")
                } footer: {
                    Text("Tiled sheets have no border: the drawing runs to the cut line, with crop marks in the margin and targets across every seam.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 300)
            .frame(maxHeight: .infinity)
            Divider()
            if previewBoard {
                LivePDFPreview(key: BoardPreviewKey(harness: doc.harness, options: boardOptions)) { [harness = doc.harness, boardOptions] in
                    Formboard.make(harness, options: boardOptions, library: LibraryStore.shared.library)
                }
            } else {
                LivePDFPreview(key: ExportPreviewKey(harness: doc.harness, pages: pages, sideTables: sideTables)) { [harness = doc.harness, analysis = doc.analysis, pages, sideTables] in
                    PDFDrawingSet.make(harness, analysis: analysis, pages: pages, library: LibraryStore.shared.library, tablesOnDrawingSheet: sideTables)
                }
            }
        }
    }

    private func print() {
        guard let pdf = PDFDocument(data: PDFDrawingSet.make(doc.harness, analysis: doc.analysis, pages: pages, library: LibraryStore.shared.library,
                                                             tablesOnDrawingSheet: sideTables)) else { return }
        let info = NSPrintInfo.shared
        info.orientation = .landscape
        pdf.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true)?.runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
    }
}

private struct ExportPreviewKey: Hashable {
    var harness: Harness
    var pages: [DrawingPage]
    var sideTables: Bool
}

private struct BoardPreviewKey: Hashable {
    var harness: Harness
    var options: FormboardOptions
}

/// A PDF preview that is rebuilt only when its inputs change, after typing pauses,
/// instead of on every redraw of the page.
struct LivePDFPreview<Key: Hashable>: View {
    let key: Key
    let make: () -> Data
    @State private var data: Data?

    var body: some View {
        ZStack {
            if let data {
                PDFPreview(data: data)
            } else {
                Color(nsColor: .underPageBackgroundColor)
            }
            if data == nil { ProgressView("Building preview…") }
        }
        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
        .task(id: key) {
            if data != nil { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            data = make()
        }
    }
}

struct PDFPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = .underPageBackgroundColor
        return v
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last: Data? }

    func updateNSView(_ v: PDFView, context: Context) {
        guard context.coordinator.last != data else { return }
        context.coordinator.last = data
        v.document = PDFDocument(data: data)
    }
}
