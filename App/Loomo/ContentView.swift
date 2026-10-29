import CrimpCore
import SwiftUI
import TipKit

enum Pane: String, CaseIterable, Identifiable {
    case topology = "Harness Drawing", connectors = "Connectors & Pinouts", wires = "Wires", cables = "Cables & Twists"
    case splices = "Splices", coverings = "Coverings", labels = "Labels", drawing = "Notes & Title Block"
    case bom = "Bill of Materials", cutList = "Cut List", connectorTables = "Connection Tables", netlist = "Netlist"
    case labelList = "Label List", tools = "Tools", issues = "Rule Checker", export = "Print & Export"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .topology: "point.3.connected.trianglepath.dotted"
        case .connectors: "powerplug"
        case .wires: "line.diagonal"
        case .cables: "cable.connector"
        case .splices: "arrow.triangle.merge"
        case .coverings: "cylinder.split.1x2"
        case .labels: "tag"
        case .drawing: "doc.text"
        case .bom: "list.bullet.rectangle"
        case .cutList: "scissors"
        case .connectorTables: "tablecells"
        case .netlist: "network"
        case .labelList: "tag.square"
        case .tools: "wrench.and.screwdriver"
        case .issues: "checkmark.shield"
        case .export: "printer"
        }
    }
    static let design: [Pane] = [.topology, .connectors, .wires, .cables, .splices, .coverings, .labels, .drawing]
    static let outputs: [Pane] = [.bom, .cutList, .connectorTables, .netlist, .labelList, .tools, .issues, .export]
}

struct ContentView: View {
    @ObservedObject var doc: HarnessDocument
    @Environment(\.undoManager) private var undoManager
    @State private var pane: Pane? = .topology
    @State private var showInspector = true
    @State private var showHistory = false
    /// The inspector column shows the assistant instead of the item inspector.
    @State private var showAssistant = false
    @StateObject private var assistant = HarnessAssistant()

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section("Design") { ForEach(Pane.design) { row($0) } }
                Section("Manufacturing") { ForEach(Pane.outputs) { row($0) } }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                BrandHeader(title: doc.harness.name.isEmpty ? "Loomo" : doc.harness.name, subtitle: "Harness · Rev \(doc.harness.revision)")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                let issues = doc.analysis.issues
                HealthCard(errors: issues.filter { $0.severity == .error }.count,
                           warnings: issues.filter { $0.severity == .warning }.count,
                           accepted: issues.filter { $0.acceptedReason != nil }.count) { pane = .issues }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 260)
        } detail: {
            detail
                .inspector(isPresented: $showInspector) {
                    Group {
                        if showAssistant {
                            AssistantView(assistant: assistant)
                        } else {
                            InspectorView(doc: doc, jump: { pane = $0 })
                        }
                    }
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
                }
        }
        .navigationSubtitle("Rev \(doc.harness.revision)")
        .toolbar { toolbar }
        .focusedSceneObject(doc)
        .environment(\.harnessDocument, doc)
        .modifier(ShortcutsSheetHost())
        .onAppear {
            doc.undoManager = undoManager
            assistant.attach(doc)
            NotificationCenter.default.post(name: .projectWindowOpened, object: nil)
            if case .available = assistant.availability { AssistantTip.available = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleAssistant)) { note in
            guard note.object as AnyObject? === doc else { return }
            toggleAssistant()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDrawing)) { note in
            guard note.object as AnyObject? === doc else { return }
            pane = .topology
        }
        .onChange(of: undoManager) { doc.undoManager = undoManager }
    }

    private var detail: some View {
        HarnessPaneView(doc: doc, pane: pane ?? .topology, jump: { pane = $0 })
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { undoManager?.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .help(undoManager?.undoMenuItemTitle ?? "Undo")
                .disabled(!doc.history.canUndo)
            Button { undoManager?.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .help(undoManager?.redoMenuItemTitle ?? "Redo")
                .disabled(!doc.history.canRedo)
            Button { showHistory.toggle() } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                .help("Undo history")
                .popover(isPresented: $showHistory, arrowEdge: .bottom) { HistoryList(doc: doc) }
        }
        ToolbarItemGroup {
            Menu {
                Button("Wire Between Connectors…") { doc.requestWire() }
                Menu("Covering") {
                    ForEach(CoveringKind.allCases, id: \.self) { k in Button(k.title) { doc.addCovering(k) } }
                }
                Button("Import Wire List…") { doc.importWireList() }
            } label: { Label("Add", systemImage: "plus") }
            Button { pane = .issues } label: {
                let errors = doc.analysis.issues.filter { $0.severity == .error }.count
                let warnings = doc.analysis.issues.filter { $0.severity == .warning }.count
                Label(errors + warnings == 0 ? "No issues" : "\(errors) errors, \(warnings) warnings",
                      systemImage: errors > 0 ? "xmark.octagon" : warnings > 0 ? "exclamationmark.triangle" : "checkmark.seal")
                    .foregroundStyle(errors > 0 ? .red : warnings > 0 ? .orange : .green)
            }
            .help("Rule checker")
            Menu {
                Button("Drawing Set (PDF)…") { doc.exportPDF() }
                Button("Formboard 1:1 (PDF)…") { doc.exportFormboard() }
                Button("Excel Workbook…") { doc.exportExcel() }
                Button("WireViz YAML…") { doc.exportWireViz() }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            Button { doc.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                .disabled(doc.selection == nil)
            Button { toggleAssistant() } label: { Label("Assistant", systemImage: showAssistant && showInspector ? "sparkles.rectangle.stack.fill" : "sparkles") }
                .help("Harness assistant (⌥⌘A)")
                .popoverTip(AssistantTip(), arrowEdge: .top)
            Button {
                if showAssistant { showAssistant = false; showInspector = true } else { showInspector.toggle() }
            } label: { Label("Inspector", systemImage: "sidebar.right") }
        }
    }

    private func toggleAssistant() {
        AssistantTip().invalidate(reason: .actionPerformed)
        if showAssistant && showInspector {
            showAssistant = false
        } else {
            showAssistant = true
            showInspector = true
        }
    }

    @ViewBuilder private func row(_ p: Pane) -> some View {
        let h = doc.harness
        let badge: Int = switch p {
        case .connectors: h.connectors.count
        case .wires: h.wires.count
        case .cables: h.cables.count + h.twists.count
        case .splices: h.splices.count
        case .coverings: h.coverings.count
        case .labels: h.labels.count
        case .issues: doc.analysis.issues.filter { $0.severity != .info }.count
        default: 0
        }
        let errors = p == .issues && doc.analysis.issues.contains { $0.severity == .error }
        SidebarRow(pane: p, count: badge, countTint: p == .issues ? (errors ? .red : .orange) : nil).tag(p)
    }
}

/// RapidHarness-style history list: click an entry to undo back to it.
private struct HistoryList: View {
    @ObservedObject var doc: HarnessDocument

    var body: some View {
        let undo = doc.history.undoStack.map(\.name).reversed()
        let redo = doc.history.redoStack.map(\.name)
        VStack(alignment: .leading, spacing: 0) {
            Text("History").font(.headline).padding(10)
            Divider()
            List {
                ForEach(Array(redo.enumerated()), id: \.offset) { _, name in
                    Label(name, systemImage: "arrow.uturn.forward").foregroundStyle(.tertiary)
                }
                Label("Current state", systemImage: "circle.fill").foregroundStyle(Color.accentColor)
                ForEach(Array(undo.enumerated()), id: \.offset) { i, name in
                    Button { doc.undo(steps: i + 1) } label: {
                        Label(name, systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                }
                if undo.isEmpty && redo.isEmpty { Text("No changes yet").foregroundStyle(.secondary) }
            }
            .frame(width: 280, height: 320)
        }
    }
}

/// One page of the harness editor. Used by harness windows and by harnesses embedded in a system project.
struct HarnessPaneView: View {
    @ObservedObject var doc: HarnessDocument
    let pane: Pane
    var jump: (Pane) -> Void

    var body: some View {
        Group {
            if pane == .topology {
                page
            } else {
                VStack(spacing: 0) {
                    PaneHeader(pane: pane, subtitle: subtitle)
                    page
                        .glassPanel()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                .background(AmbientBackground(tint: pane.tint))
            }
        }
            .sheet(item: $doc.wireRequest) { NewWireSheet(doc: doc, request: $0) }
            .sheet(item: $doc.faceEditor) { FaceLayoutEditor(doc: doc, connectorID: $0.id) }
            .sheet(item: $doc.cropTarget) { ConnectorPictureCropSheet(doc: doc, target: $0) }
            .sheet(item: $doc.passThrough) { PassThroughSheet(doc: doc, request: $0) }
            .sheet(item: $doc.remap) { RemapSheet(doc: doc, request: $0) }
    }

    /// A live one-line summary under the page title.
    private var subtitle: String? {
        let h = doc.harness, a = doc.analysis
        switch pane {
        case .connectors: return "\(h.connectors.count) connectors · \(h.connectors.reduce(0) { $0 + $1.cavities.count }) cavities"
        case .wires: return "\(h.wires.count) wires · \(doc.units.format(a.routes.values.compactMap(\.lengthMM).reduce(0, +))) total"
        case .splices: return "\(h.splices.count) splices"
        case .bom: return "\(a.bom.count) lines"
        case .issues:
            let e = a.issues.filter { $0.severity == .error }.count, w = a.issues.filter { $0.severity == .warning }.count
            return e + w == 0 ? "Everything checks out" : "\(e) errors · \(w) warnings"
        default: return nil
        }
    }

    @ViewBuilder private var page: some View {
        switch pane {
        case .topology: TopologyCanvas(doc: doc, jump: jump)
        case .connectors: ConnectorsPane(doc: doc)
        case .wires: WiresTable(doc: doc)
        case .cables: CablesPane(doc: doc)
        case .splices: SplicesTable(doc: doc)
        case .coverings: CoveringsTable(doc: doc)
        case .labels: LabelsTable(doc: doc)
        case .drawing: DrawingInfoPane(doc: doc)
        case .bom: BOMView(doc: doc)
        case .cutList: CutListView(doc: doc)
        case .connectorTables: ConnectorTablesView(doc: doc)
        case .netlist: NetlistView(doc: doc)
        case .labelList: LabelListView(doc: doc)
        case .tools: ToolsView(doc: doc)
        case .issues: IssuesView(doc: doc, jump: jump)
        case .export: ExportPane(doc: doc)
        }
    }
}
