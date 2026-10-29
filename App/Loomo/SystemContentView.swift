import CrimpCore
import CrimpOutputs
import SwiftUI

enum SystemPane: Hashable {
    case diagram, devices, mates, trace, netlist, bom, issues, export
    case harness(EntityID)

    static let systemPanes: [SystemPane] = [.diagram, .devices, .mates, .trace, .netlist, .bom, .issues, .export]

    var title: String {
        switch self {
        case .diagram: "System Diagram"
        case .devices: "Devices"
        case .mates: "Mates"
        case .trace: "Signal Trace"
        case .netlist: "System Netlist"
        case .bom: "System BOM"
        case .issues: "Rule Checker"
        case .export: "Print & Export"
        case let .harness(id): id
        }
    }

    var icon: String {
        switch self {
        case .diagram: "rectangle.connected.to.line.below"
        case .devices: "cpu"
        case .mates: "powerplug.portrait"
        case .trace: "point.topleft.down.to.point.bottomright.curvepath"
        case .netlist: "network"
        case .bom: "list.bullet.rectangle"
        case .issues: "checkmark.shield"
        case .export: "printer"
        case .harness: "cable.connector.horizontal"
        }
    }

    var tint: Color {
        switch self {
        case .diagram: Color(red: 0.20, green: 0.55, blue: 1.00)
        case .devices: Color(red: 0.55, green: 0.40, blue: 0.95)
        case .mates: Color(red: 1.00, green: 0.55, blue: 0.15)
        case .trace: Color(red: 0.20, green: 0.78, blue: 0.45)
        case .netlist: Color(red: 0.15, green: 0.65, blue: 0.95)
        case .bom: Color(red: 0.36, green: 0.40, blue: 0.95)
        case .issues: Color(red: 0.30, green: 0.75, blue: 0.40)
        case .export: Color(red: 0.55, green: 0.35, blue: 0.95)
        case .harness: Color(red: 0.10, green: 0.72, blue: 0.75)
        }
    }

    var blurb: String {
        switch self {
        case .diagram: "Devices, harnesses and how they mate"
        case .devices: "ECUs, sensors and other equipment"
        case .mates: "Which connectors plug into which"
        case .trace: "Follow a signal across harnesses"
        case .netlist: "Every net in the system"
        case .bom: "Parts for the whole system"
        case .issues: "System-level rule checks"
        case .export: "System drawing set and workbook"
        case .harness: ""
        }
    }
}

struct SystemContentView: View {
    @ObservedObject var doc: SystemDocument
    @EnvironmentObject var library: LibraryStore
    @Environment(\.undoManager) private var undoManager
    @State private var pane: SystemPane? = .diagram
    @State private var harnessPane: Pane = .topology
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section("System") {
                    ForEach(SystemPane.systemPanes, id: \.self) { p in
                        SidebarRow(title: p.title, icon: p.icon, tint: p.tint, count: badge(p),
                                   countTint: p == .issues ? .orange : nil).tag(p)
                    }
                }
                Section("Harnesses") {
                    ForEach(doc.project.harnesses) { inst in
                        SidebarRow(title: inst.id, icon: "cable.connector.horizontal", tint: SystemPane.harness(inst.id).tint,
                                   detail: inst.harness.name + (inst.quantity > 1 ? " ×\(inst.quantity)" : ""),
                                   count: doc.analysis.harnessAnalyses[inst.id]?.issues.filter { $0.severity == .error }.count ?? 0,
                                   countTint: .red)
                        .tag(SystemPane.harness(inst.id))
                        .contextMenu {
                            Button("Duplicate") { doc.duplicateHarness(inst.id) }
                            Button("Export as .loomo…") { doc.exportHarness(inst.id) }
                            Button("Remove from System", role: .destructive) { doc.selection = .harness(inst.id); doc.deleteSelection() }
                        }
                    }
                    AddHarnessMenu(doc: doc)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                BrandHeader(title: doc.project.name.isEmpty ? "Loomo" : doc.project.name, subtitle: "System · Rev \(doc.project.revision)")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                let issues = doc.analysis.issues
                HealthCard(errors: issues.filter { $0.severity == .error }.count,
                           warnings: issues.filter { $0.severity == .warning }.count) { pane = .issues }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            detail
        }
        .navigationSubtitle("System · Rev \(doc.project.revision)")
        .toolbar { toolbar }
        .focusedSceneObject(doc)
        .modifier(ShortcutsSheetHost())
        .onAppear {
            doc.undoManager = undoManager
            NotificationCenter.default.post(name: .projectWindowOpened, object: nil)
        }
        .onChange(of: undoManager) { doc.undoManager = undoManager }
    }

    @ViewBuilder private var detail: some View {
        switch pane ?? .diagram {
        case let .harness(id):
            if let child = doc.harnessDocument(for: id) {
                HarnessWorkspace(doc: child, pane: $harnessPane)
                    .id(id)
            } else {
                ContentUnavailableView("Harness removed", systemImage: "cable.connector.horizontal")
            }
        default:
            let p = pane ?? .diagram
            VStack(spacing: 0) {
                PaneHeader(title: p.title, icon: p.icon, tint: p.tint, subtitle: p.blurb)
                systemDetail
                    .glassPanel()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
            .background(AmbientBackground(tint: p.tint))
                .inspector(isPresented: $showInspector) {
                    SystemInspector(doc: doc, open: { pane = $0 })
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
                }
        }
    }

    @ViewBuilder private var systemDetail: some View {
        switch pane ?? .diagram {
        case .diagram: SystemDiagramView(doc: doc, open: { pane = $0 })
        case .devices: DevicesPane(doc: doc)
        case .mates: MatesPane(doc: doc)
        case .trace: SignalTracePane(doc: doc, open: { open(harness: $0, select: $1, page: $2) })
        case .netlist: SystemNetlistPane(doc: doc, open: { open(harness: $0, select: $1, page: $2) })
        case .bom: SystemBOMPane(doc: doc)
        case .issues: SystemIssuesPane(doc: doc, open: { open(harness: $0, select: $1, page: $2) })
        case .export: SystemExportPane(doc: doc)
        case .harness: EmptyView()
        }
    }

    /// Opens a harness at a page with an item selected (from traces, nets and rule checks).
    private func open(harness id: EntityID, select subject: EntityID?, page: Pane) {
        pane = .harness(id)
        harnessPane = page
        if let subject, let child = doc.harnessDocument(for: id) {
            child.selection = child.selection(for: subject)
        }
    }

    private func badge(_ p: SystemPane) -> Int {
        switch p {
        case .devices: doc.project.devices.count
        case .mates: doc.project.mates.count
        case .netlist: doc.analysis.nets.count
        case .issues: doc.analysis.issues.filter { $0.severity != .info }.count
        default: 0
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { undoManager?.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(undoManager?.canUndo != true)
            Button { undoManager?.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(undoManager?.canRedo != true)
        }
        ToolbarItemGroup {
            Button { doc.addDevice(); pane = .diagram } label: { Label("Add Device", systemImage: "cpu") }
            Button { doc.autoMate() } label: { Label("Auto-Mate", systemImage: "wand.and.stars") }
                .help("Mate harness connectors to device connectors with matching names")
            Button { pane = .issues } label: {
                let errors = doc.analysis.issues.filter { $0.severity == .error }.count
                let warnings = doc.analysis.issues.filter { $0.severity == .warning }.count
                Label("\(errors) errors, \(warnings) warnings", systemImage: errors > 0 ? "xmark.octagon" : warnings > 0 ? "exclamationmark.triangle" : "checkmark.seal")
                    .foregroundStyle(errors > 0 ? Color.red : warnings > 0 ? Color.orange : Color.green)
            }
            Menu {
                Button("System Drawing Set (PDF)…") { doc.exportPDF() }
                Button("System Workbook (Excel)…") { doc.exportExcel() }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            if case .harness = pane {
                EmptyView()
            } else {
                Button { doc.deleteSelection() } label: { Label("Delete", systemImage: "trash") }.disabled(doc.selection == nil)
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
    }
}

struct AddHarnessMenu: View {
    @ObservedObject var doc: SystemDocument

    var body: some View {
        Menu {
            Button("New Empty Harness") { doc.addHarness(Harness(name: "New harness")) }
            Button("Import .loomo File…") { doc.importHarness() }
        } label: { Label("Add Harness", systemImage: "plus") }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
    }
}

/// The full harness editor for one harness instance, hosted inside the system window.
struct HarnessWorkspace: View {
    @ObservedObject var doc: HarnessDocument
    @Binding var pane: Pane
    @State private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconTile(systemName: pane.icon, tint: pane.tint, size: 26)
                Picker("Page", selection: $pane) {
                    Section("Design") { ForEach(Pane.design) { Label($0.rawValue, systemImage: $0.icon).tag($0) } }
                    Section("Manufacturing") { ForEach(Pane.outputs) { Label($0.rawValue, systemImage: $0.icon).tag($0) } }
                }
                .labelsHidden()
                .fixedSize()
                Text(doc.harness.name).font(.headline)
                Spacer()
                Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.glass)
                    .help("Inspector")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            HarnessPaneView(doc: doc, pane: pane, jump: { pane = $0 })
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(doc: doc, jump: { pane = $0 })
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .environment(\.harnessDocument, doc)
        .focusedSceneObject(doc)
    }
}
