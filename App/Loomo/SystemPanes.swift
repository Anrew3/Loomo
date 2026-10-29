import CrimpCore
import CrimpOutputs
import SwiftUI

typealias OpenHarness = (_ harness: EntityID, _ select: EntityID?, _ page: Pane) -> Void

// MARK: - Diagram

struct SystemDiagramView: View {
    @ObservedObject var doc: SystemDocument
    var open: (SystemPane) -> Void

    private enum Drag { case block(SystemBlockID, Point2D), connect(ConnectorRef), none }
    @State private var drag: Drag?
    @State private var dragPoint: CGPoint?
    @State private var zoom: CGFloat = 1

    var body: some View {
        let layout = SystemLayout(doc.project)
        var opts = SystemRenderer.Options()
        if case let .device(d)? = doc.selection { opts.selectedBlock = .device(d) }
        if case let .harness(h)? = doc.selection { opts.selectedBlock = .harness(h) }
        if case let .mate(m)? = doc.selection { opts.selectedMate = m }
        if case let .connect(ref)? = drag { opts.pendingPort = ref }
        let hot = highlighted()
        opts.highlightConnectors = hot.connectors
        opts.highlightMates = hot.mates
        opts.ink = NSColor.labelColor.cgColor
        opts.secondaryInk = NSColor.secondaryLabelColor.cgColor
        opts.paper = NSColor.textBackgroundColor.cgColor
        opts.accent = NSColor.controlAccentColor.cgColor
        let renderer = SystemRenderer(project: doc.project, layout: layout, options: opts)
        let b = layout.bounds
        let size = CGSize(width: max(b.isNull ? 0 : b.maxX + 300, 1400) * zoom, height: max(b.isNull ? 0 : b.maxY + 300, 900) * zoom)

        return VStack(spacing: 0) {
            HStack {
                Button { doc.addDevice() } label: { Label("Device", systemImage: "plus") }
                AddHarnessMenu(doc: doc).fixedSize()
                Button("Auto-Mate by Name") { doc.autoMate() }
                if let pin = doc.tracePin {
                    Divider().frame(height: 16)
                    Label("Tracing \(doc.analysis.netOf[pin] ?? pin)", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .foregroundStyle(.orange)
                    Button("Clear") { doc.tracePin = nil }
                }
                Spacer()
                ControlGroup {
                    Button { zoom = max(0.3, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { zoom = 1 } label: { Text("\(Int(zoom * 100))%").monospacedDigit() }
                    Button { zoom = min(3, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                }.fixedSize()
            }
            .padding(8)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Canvas { ctx, _ in
                    ctx.withCGContext { cg in
                        cg.scaleBy(x: zoom, y: zoom)
                        renderer.draw(in: cg)
                        if case let .connect(ref)? = drag, let p = dragPoint, let ports = layout.ports(ref) {
                            let start = hypot(ports.left.x - p.x, ports.left.y - p.y) < hypot(ports.right.x - p.x, ports.right.y - p.y) ? ports.left : ports.right
                            cg.setStrokeColor(NSColor.controlAccentColor.cgColor)
                            cg.setLineWidth(2)
                            cg.setLineDash(phase: 0, lengths: [5, 3])
                            cg.move(to: start)
                            cg.addLine(to: p)
                            cg.strokePath()
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in changed(v, layout) }
                    .onEnded { v in ended(v, layout) })
                .overlay(RightClickMenu { contextMenu(at: model($0), layout) })
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            Text(drag.map { if case .connect = $0 { return "Release over another connector to mate them." } else { return "" } } ?? "Drag a block's title to move it. Drag from one connector row to another to mate them. Double-click a harness to edit it.")
                .font(.caption).foregroundStyle(.secondary).padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func contextMenu(at p: CGPoint, _ layout: SystemLayout) -> NSMenu? {
        let m = MenuBuilder()
        if let mid = layout.hitMate(p, mates: doc.project.mates), let mate = doc.project.mates.first(where: { $0.id == mid }) {
            doc.selection = .mate(mid)
            m.header("\(mid): \(mate.a) ⇄ \(mate.b)")
            m.item("Edit Pin Map…", image: "slider.horizontal.3") { doc.selection = .mate(mid) }
            m.item("Unmate", key: "\u{8}", image: "powerplug.portrait") { doc.deleteSelection() }
            return m.menu
        }
        if let block = layout.hitBlock(p) {
            let row = layout.hitRow(p)
            switch block.id {
            case let .harness(h):
                doc.selection = .harness(h)
                m.header("Harness \(block.title) · \(block.subtitle)")
                m.item("Open Harness Editor", key: "\r", image: "pencil") { open(.harness(h)) }
                m.item("Duplicate", image: "plus.square.on.square") { doc.duplicateHarness(h) }
                m.item("Export as .loomo…", image: "square.and.arrow.up") { doc.exportHarness(h) }
            case let .device(d):
                doc.selection = .device(d)
                m.header("Device \(block.title) · \(block.subtitle)")
                m.item("Edit Connectors and Pins…", image: "cpu") { open(.devices) }
            }
            if let row {
                m.separator()
                m.header(doc.project.displayName(of: row))
                if let pin = doc.project.pins(of: row)?.first { m.item("Trace Net", image: "point.topleft.down.to.point.bottomright.curvepath") { doc.tracePin = SystemPin(row, pin.label).key } }
                if doc.project.mate(for: row) != nil {
                    m.item("Unmate", image: "powerplug.portrait") { doc.perform("Unmate") { $0.mates.removeAll { $0.involves(row) } } }
                }
                if case .harness = row, doc.project.mate(for: row) == nil {
                    m.submenu("Create Mating Connector On", image: "plus") { sub in
                        for dev in doc.project.devices { sub.item(dev.id) { doc.perform("Add Mating Connector") { $0.addMatingDeviceConnector(for: row, on: dev.id) } } }
                    }
                }
            }
            m.separator()
            m.item("Remove from System", key: "\u{8}", image: "trash") { doc.deleteSelection() }
            return m.menu
        }
        m.item("Add Device", image: "cpu") { doc.addDevice() }
        m.submenu("Add Harness", image: "plus") { sub in
            sub.item("New Empty Harness") { doc.addHarness(Harness(name: "New harness")) }
            sub.item("Import .loomo File…") { doc.importHarness() }
        }
        m.item("Auto-Mate by Name", image: "wand.and.stars") { doc.autoMate() }
        if doc.tracePin != nil { m.item("Clear Trace") { doc.tracePin = nil } }
        return m.menu
    }

    private func highlighted() -> (connectors: Set<ConnectorRef>, mates: Set<EntityID>) {
        guard let pin = doc.tracePin, let net = doc.analysis.netOf[pin] else { return ([], []) }
        let keys = doc.analysis.netOf.filter { $0.value == net }.map(\.key)
        var refs: Set<ConnectorRef> = []
        for ref in doc.project.harnesses.flatMap({ i in i.harness.connectors.map { ConnectorRef.harness(i.id, connector: $0.id) } })
            + doc.project.devices.flatMap({ d in d.connectors.map { ConnectorRef.device(d.id, connector: $0.id) } })
            where keys.contains(where: { $0.hasPrefix(ref.description + ":") }) {
            refs.insert(ref)
        }
        let mates = Set(doc.project.mates.filter { refs.contains($0.a) && refs.contains($0.b) }.map(\.id))
        return (refs, mates)
    }

    private func model(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / zoom, y: p.y / zoom) }

    private func changed(_ v: DragGesture.Value, _ layout: SystemLayout) {
        let start = model(v.startLocation)
        if drag == nil {
            if let block = layout.hitBlock(start), start.y < block.frame.minY + SystemLayout.headerHeight, let origin = doc.blockOrigin(block.id) {
                drag = .block(block.id, origin)
            } else if let row = layout.hitRow(start) {
                drag = .connect(row)
            } else {
                drag = Drag.none
            }
        }
        guard hypot(v.translation.width, v.translation.height) > 3 else { return }
        switch drag {
        case let .block(id, origin)?:
            doc.moveBlock(id, to: Point2D(origin.x + v.translation.width / zoom, origin.y + v.translation.height / zoom))
        case .connect?:
            dragPoint = model(v.location)
        default: break
        }
    }

    private func ended(_ v: DragGesture.Value, _ layout: SystemLayout) {
        defer { drag = nil; dragPoint = nil }
        let p = model(v.location)
        let moved = hypot(v.translation.width, v.translation.height) > 3
        if case let .connect(from)? = drag, moved {
            if let to = layout.hitRow(p), to != from { doc.addMate(from, to) }
            return
        }
        guard !moved else { return }
        // Click
        if let m = layout.hitMate(p, mates: doc.project.mates) {
            doc.selection = .mate(m)
        } else if let block = layout.hitBlock(p) {
            switch block.id {
            case let .device(d): doc.selection = .device(d)
            case let .harness(h):
                if doc.selection == .harness(h), NSApp.currentEvent?.clickCount ?? 1 >= 2 { open(.harness(h)) }
                doc.selection = .harness(h)
            }
            if let row = layout.hitRow(p), let pin = doc.project.pins(of: row)?.first {
                // Clicking a connector row traces its first wired pin's net.
                let key = SystemPin(row, pin.label).key
                if doc.analysis.netOf[key] != nil { doc.tracePin = key }
            }
        } else {
            doc.selection = nil
        }
    }
}

// MARK: - Devices

struct DevicesPane: View {
    @ObservedObject var doc: SystemDocument
    @State private var connectorID: EntityID?

    var body: some View {
        let selectedDevice: EntityID? = if case let .device(d)? = doc.selection { d } else { nil }
        VSplitView {
            Table(doc.project.devices, selection: Binding(
                get: { selectedDevice },
                set: { doc.selection = $0.map(SystemSelection.device) })) {
                TableColumn("ID", value: \.id).width(70)
                TableColumn("Name", value: \.name)
                TableColumn("Part") { Text($0.part?.mpn ?? "—") }
                TableColumn("Connectors") { Text($0.connectors.map(\.id).joined(separator: ", ")) }
                TableColumn("Pins") { Text("\($0.connectors.map(\.pins.count).reduce(0, +))") }.width(50)
            }
            .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 180)
            Group {
                if let d = selectedDevice, let dev = doc.project.device(d) {
                    deviceDetail(dev)
                } else {
                    ContentUnavailableView("Select a device", systemImage: "cpu", description: Text("Its connectors and pin lists appear here."))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        }
    }

    private func deviceDetail(_ dev: Device) -> some View {
        let conID = connectorID.flatMap { id in dev.connectors.contains { $0.id == id } ? id : nil } ?? dev.connectors.first?.id
        return HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(dev.id) connectors").font(.headline)
                List(dev.connectors, selection: Binding(get: { conID }, set: { connectorID = $0 })) { c in
                    HStack {
                        Text(c.id).monospaced()
                        Text(c.name).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(c.pins.count)p").font(.caption)
                        if doc.project.mate(for: .device(dev.id, connector: c.id)) == nil { Image(systemName: "circle.dashed").foregroundStyle(.orange).help("Not mated") }
                    }
                    .tag(c.id)
                }
                HStack {
                    Button("Add Connector") {
                        doc.perform("Add Device Connector") { p in
                            guard let i = p.devices.firstIndex(where: { $0.id == dev.id }) else { return }
                            var n = 1
                            while p.devices[i].connectors.contains(where: { $0.id == "J\(n)" }) { n += 1 }
                            p.devices[i].connectors.append(DeviceConnector(id: "J\(n)", pinCount: 4))
                            connectorID = "J\(n)"
                        }
                    }
                    Menu("Mating Connector for…") {
                        ForEach(unmatedHarnessConnectors, id: \.self) { ref in
                            Button(doc.project.displayName(of: ref)) {
                                doc.perform("Add Mating Connector") { $0.addMatingDeviceConnector(for: ref, on: dev.id) }
                            }
                        }
                    }
                    .help("Creates a device connector with the opposite gender and the same pins and signals, and mates it")
                    .disabled(unmatedHarnessConnectors.isEmpty)
                }
            }
            .padding(8)
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
            if let cid = conID, let ci = dev.connectors.firstIndex(where: { $0.id == cid }),
               let di = doc.project.devices.firstIndex(where: { $0.id == dev.id }) {
                PinTable(doc: doc, deviceIndex: di, connectorIndex: ci)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var unmatedHarnessConnectors: [ConnectorRef] {
        doc.project.allConnectorRefs.filter { if case .harness = $0 { return doc.project.mate(for: $0) == nil } else { return false } }
    }
}

private struct PinRow: Identifiable { let id: Int }

private struct PinTable: View {
    @ObservedObject var doc: SystemDocument
    let deviceIndex: Int
    let connectorIndex: Int

    var body: some View {
        let d = doc.project.devices[safe: deviceIndex]
        let c = d?.connectors[safe: connectorIndex]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(d?.id ?? "")/\(c?.id ?? "") pins").font(.headline)
                Spacer()
                Stepper("Pins: \(c?.pins.count ?? 0)", value: Binding(
                    get: { c?.pins.count ?? 0 },
                    set: { n in edit { con in
                        if n > con.pins.count { con.pins += (con.pins.count + 1...n).map { DevicePin(label: String($0)) } }
                        else if n >= 1 { con.pins.removeLast(con.pins.count - n) }
                    } }), in: 1...500).fixedSize()
                Button("Import Pin List…") { if let d, let c { doc.importPinList(device: d.id, connector: c.id) } }
            }
            if let d, let c {
                Table(c.pins.indices.map(PinRow.init)) {
                    TableColumn("Pin") { r in Text(c.pins[r.id].label).monospaced() }.width(60)
                    TableColumn("Signal") { r in
                        let i = r.id
                        TextField("Signal", text: Binding(
                            get: { doc.project.devices[safe: deviceIndex]?.connectors[safe: connectorIndex]?.pins[safe: i]?.signal ?? "" },
                            set: { v in edit { $0.pins[i].signal = v.isEmpty ? nil : v } }))
                    }
                    TableColumn("System net") { r in
                        Text(doc.analysis.netOf[SystemPin(.device(d.id, connector: c.id), c.pins[r.id].label).key] ?? "—")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(8)
    }

    private func edit(_ change: (inout DeviceConnector) -> Void) {
        guard deviceIndex < doc.project.devices.count, connectorIndex < doc.project.devices[deviceIndex].connectors.count else { return }
        change(&doc.project.devices[deviceIndex].connectors[connectorIndex])
    }
}

// MARK: - Mates

struct MatesPane: View {
    @ObservedObject var doc: SystemDocument

    var body: some View {
        let p = doc.project
        let selected: EntityID? = if case let .mate(m)? = doc.selection { m } else { nil }
        VStack(spacing: 0) {
            Table(p.mates, selection: Binding(get: { selected }, set: { doc.selection = $0.map(SystemSelection.mate) })) {
                TableColumn("Mate", value: \.id).width(50)
                TableColumn("Side A") { Text(p.displayName(of: $0.a)) }
                TableColumn("Side B") { Text(p.displayName(of: $0.b)) }
                TableColumn("Pins") { m in Text("\(p.pins(of: m.a)?.count ?? 0) ⇄ \(p.pins(of: m.b)?.count ?? 0)") }.width(60)
                TableColumn("Pin map") { Text($0.pinMap.isEmpty ? "1:1 by label" : "\($0.pinMap.count) remapped") }
                TableColumn("Issues") { m in
                    let n = doc.analysis.issues.filter { $0.subject == m.id && $0.severity != .info }.count
                    Text(n == 0 ? "" : "\(n)").foregroundStyle(.orange)
                }.width(50)
            }
            Divider()
            HStack {
                Text("Create mates by dragging between connectors on the System Diagram.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Auto-Mate by Name") { doc.autoMate() }
                Button("Delete Mate") { doc.deleteSelection() }.disabled(selected == nil)
            }
            .padding(8)
        }
    }
}

// MARK: - Signal trace and netlist

struct SignalTracePane: View {
    @ObservedObject var doc: SystemDocument
    var open: OpenHarness

    var body: some View {
        let pins = allPins
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Start at", selection: Binding(get: { doc.tracePin ?? "" }, set: { doc.tracePin = $0.isEmpty ? nil : $0 })) {
                    Text("Choose a pin…").tag("")
                    Section("Device pins") { ForEach(pins.device, id: \.self) { Text(label($0)).tag($0) } }
                    Section("Harness pins") { ForEach(pins.harness, id: \.self) { Text(label($0)).tag($0) } }
                }
                .frame(maxWidth: 420)
                if let pin = doc.tracePin, let net = doc.analysis.netOf[pin] {
                    Text("Net \(net)").font(.headline)
                }
                Spacer()
            }
            if let pin = doc.tracePin {
                TraceList(doc: doc, start: pin, open: open)
            } else {
                ContentUnavailableView("Choose a pin to trace", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                       description: Text("The trace follows wires, splices and mated connectors across every harness."))
            }
        }
        .padding()
    }

    private var allPins: (device: [String], harness: [String]) {
        let p = doc.project
        let device = p.devices.flatMap { d in d.connectors.flatMap { c in c.pins.map { SystemPin(.device(d.id, connector: c.id), $0.label).key } } }
        let harness = p.harnesses.flatMap { i in i.harness.connectors.flatMap { c in c.cavities.map { SystemPin(.harness(i.id, connector: c.id), $0.label).key } } }
        return (device, harness)
    }

    private func label(_ key: String) -> String {
        if let net = doc.analysis.netOf[key] { return "\(key)  (\(net))" }
        return key
    }
}

struct TraceList: View {
    @ObservedObject var doc: SystemDocument
    let start: String
    var open: OpenHarness

    var body: some View {
        let steps = doc.analysis.trace(from: start)
        List {
            HStack {
                Image(systemName: "smallcircle.filled.circle").foregroundStyle(.orange)
                Text(start).monospaced().bold()
            }
            ForEach(steps) { s in
                HStack(spacing: 8) {
                    Color.clear.frame(width: CGFloat(s.depth - 1) * 14, height: 1)
                    switch s.via {
                    case let .wire(h, w):
                        Image(systemName: "line.diagonal").foregroundStyle(.secondary)
                        Button("\(h)/\(w)") { open(h, w, .wires) }.buttonStyle(.link).monospaced()
                        Text(s.detail).font(.caption).foregroundStyle(.secondary)
                    case let .mate(m):
                        Image(systemName: "powerplug.portrait").foregroundStyle(.secondary)
                        Button(m) { doc.selection = .mate(m) }.buttonStyle(.link).monospaced()
                        Text("mated").font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                    Text(s.to).monospaced()
                    if let sig = deviceSignal(s.to) { Text(sig).font(.caption.bold()).foregroundStyle(.orange) }
                }
            }
            if steps.isEmpty { Text("Nothing is connected to this pin.").foregroundStyle(.secondary) }
        }
    }

    private func deviceSignal(_ key: String) -> String? {
        for d in doc.project.devices {
            for c in d.connectors {
                for p in c.pins where SystemPin(.device(d.id, connector: c.id), p.label).key == key { return p.signal }
            }
        }
        return nil
    }
}

struct SystemNetlistPane: View {
    @ObservedObject var doc: SystemDocument
    var open: OpenHarness
    @State private var selected: String?

    var body: some View {
        VSplitView {
            Table(doc.analysis.nets, selection: $selected) {
                TableColumn("Net", value: \.name).width(110)
                TableColumn("Device pins") { Text($0.devicePins.joined(separator: ", ")) }
                TableColumn("Harness pins") { n in Text(n.pins.filter { !n.devicePins.contains($0) }.joined(separator: ", ")) }
                TableColumn("Wires") { Text($0.wires.joined(separator: ", ")) }
                TableColumn("Harnesses") { Text($0.harnesses.joined(separator: ", ")) }.width(80)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
            .onChange(of: selected) {
                if let n = doc.analysis.nets.first(where: { $0.name == selected }) { doc.tracePin = n.devicePins.first ?? n.pins.first }
            }
            Group {
                if let n = doc.analysis.nets.first(where: { $0.name == selected }), let start = n.devicePins.first ?? n.pins.first {
                    TraceList(doc: doc, start: start, open: open)
                } else {
                    ContentUnavailableView("Select a net", systemImage: "network", description: Text("Its path through the system appears here and is highlighted on the diagram."))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}

// MARK: - BOM, rules, export

struct SystemBOMPane: View {
    @ObservedObject var doc: SystemDocument
    @State private var sortOrder = [KeyPathComparator(\SystemBOMLine.line.category)]

    var body: some View {
        let rows = doc.analysis.bom.sorted(using: sortOrder)
        VStack(spacing: 0) {
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Category", value: \.line.category).width(85)
                TableColumn("MPN", value: \.line.mpn)
                TableColumn("Manufacturer", value: \.line.manufacturer)
                TableColumn("Description", value: \.line.description)
                TableColumn("Total") { b in
                    Text(b.line.unit == .mm ? String(format: "%.0f mm", b.line.quantity) : String(format: "%g", b.line.quantity)).monospacedDigit().bold()
                }.width(80)
                TableColumn("By harness") { b in
                    Text(b.breakdown.sorted { naturalLess($0.key, $1.key) }
                        .map { "\($0.key): " + (b.line.unit == .mm ? String(format: "%.0f", $0.value) : String(format: "%g", $0.value)) }
                        .joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                TableColumn("References") { Text($0.line.references.joined(separator: " ")) }
            }
            Divider()
            HStack {
                Text("\(rows.count) lines across \(doc.project.harnesses.count) harnesses; quantities include each harness's ×quantity.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Export Excel…") { doc.exportExcel() }
            }
            .padding(8)
        }
    }
}

struct SystemIssuesPane: View {
    @ObservedObject var doc: SystemDocument
    var open: OpenHarness

    var body: some View {
        let issues = doc.analysis.issues
        if issues.isEmpty {
            ContentUnavailableView("No issues", systemImage: "checkmark.seal", description: Text("Every system and harness rule check passed."))
        } else {
            List(issues) { issue in
                Button { go(issue.subject) } label: {
                    HStack(alignment: .top) {
                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(issue.severity == .error ? Color.red : issue.severity == .warning ? Color.orange : Color.secondary)
                        Text(issue.subject).bold().frame(width: 110, alignment: .leading)
                        Text(issue.message)
                        Spacer()
                        Image(systemName: "arrow.right.circle").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func go(_ subject: String) {
        let p = doc.project
        if p.mates.contains(where: { $0.id == subject }) { doc.selection = .mate(subject); return }
        if doc.analysis.nets.contains(where: { $0.name == subject }), let n = doc.analysis.nets.first(where: { $0.name == subject }) {
            doc.tracePin = n.devicePins.first ?? n.pins.first
            return
        }
        let owner = String(subject.prefix { $0 != "/" })
        let rest = subject.contains("/") ? String(subject.drop { $0 != "/" }.dropFirst()) : nil
        if p.instance(owner) != nil {
            open(owner, rest, rest == nil ? .topology : .issues)
        } else if p.device(owner) != nil {
            doc.selection = .device(owner)
        } else if doc.analysis.netOf[subject] != nil {
            doc.tracePin = subject
        }
    }
}

private struct SystemPreviewKey: Hashable {
    var project: SystemProject
    var includeHarnesses: Bool
}

struct SystemExportPane: View {
    @ObservedObject var doc: SystemDocument
    @State private var includeHarnesses = true

    var body: some View {
        // Plain HStack rather than HSplitView; see ExportPane.
        HStack(spacing: 0) {
            Form {
                Section("System drawing set") {
                    Toggle("Include every harness's drawing set", isOn: $includeHarnesses)
                    Picker("Sheet size", selection: $doc.project.titleBlock.sheetSize) {
                        ForEach(SheetSize.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Button("Export PDF…") { doc.exportPDF(includeHarnesses: includeHarnesses) }
                    Button("Export Excel Workbook…") { doc.exportExcel() }
                }
                Section("Title block") {
                    TextField("System name", text: $doc.project.name)
                    TextField("Revision", text: $doc.project.revision)
                    TextField("Company", text: $doc.project.titleBlock.company)
                    TextField("Drawing number", text: $doc.project.titleBlock.drawingNumber)
                    TextField("Drawn by", text: $doc.project.titleBlock.drawnBy)
                    TextField("Checked by", text: $doc.project.titleBlock.checkedBy)
                    TextField("Approved by", text: $doc.project.titleBlock.approvedBy)
                }
            }
            .formStyle(.grouped)
            .frame(width: 300)
            .frame(maxHeight: .infinity)
            Divider()
            LivePDFPreview(key: SystemPreviewKey(project: doc.project, includeHarnesses: includeHarnesses)) {
                [project = doc.project, analysis = doc.analysis, includeHarnesses] in
                SystemPDF.make(project, analysis: analysis, includeHarnessDrawings: includeHarnesses)
            }
        }
    }
}

// MARK: - Inspector

struct SystemInspector: View {
    @ObservedObject var doc: SystemDocument
    var open: (SystemPane) -> Void

    var body: some View {
        Form {
            switch doc.selection {
            case let .device(id)?:
                if let i = doc.project.devices.firstIndex(where: { $0.id == id }) { deviceSection(i) }
            case let .harness(id)?:
                if let i = doc.project.harnesses.firstIndex(where: { $0.id == id }) { harnessSection(i) }
            case let .mate(id)?:
                if let i = doc.project.mates.firstIndex(where: { $0.id == id }) { mateSection(i) }
            case nil:
                summary
            }
        }
        .formStyle(.grouped)
    }

    private var summary: some View {
        let p = doc.project, a = doc.analysis
        return Group {
            Section("System") {
                TextField("Name", text: $doc.project.name)
                TextField("Revision", text: $doc.project.revision)
            }
            Section("Summary") {
                LabeledContent("Devices", value: "\(p.devices.count)")
                LabeledContent("Harnesses", value: "\(p.harnesses.count) (\(p.harnesses.map(\.quantity).reduce(0, +)) built)")
                LabeledContent("Mates", value: "\(p.mates.count)")
                LabeledContent("Nets", value: "\(a.nets.count)")
                LabeledContent("Unmated connectors", value: "\(p.allConnectorRefs.filter { p.mate(for: $0) == nil }.count)")
                Button("Rule checker: \(a.issues.filter { $0.severity == .error }.count) errors, \(a.issues.filter { $0.severity == .warning }.count) warnings") { open(.issues) }
                    .buttonStyle(.link)
            }
        }
    }

    private func deviceSection(_ i: Int) -> some View {
        Group {
            Section("Device \(doc.project.devices[i].id)") {
                TextField("Name", text: $doc.project.devices[i].name)
                PartField(title: "Part", part: $doc.project.devices[i].part, category: .any)
                TextField("Notes", text: $doc.project.devices[i].notes, axis: .vertical)
                Button("Edit Connectors and Pins") { open(.devices) }.buttonStyle(.link)
            }
            Section("Connectors") {
                ForEach($doc.project.devices[i].connectors) { $c in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(c.id).monospaced().bold()
                            TextField("Name", text: $c.name)
                            Picker("", selection: $c.gender) { ForEach(Gender.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                                .labelsHidden().frame(width: 90)
                        }
                        PartField(title: "Part", part: $c.part, category: .connector)
                        let ref = ConnectorRef.device(doc.project.devices[i].id, connector: c.id)
                        Text(doc.project.mate(for: ref).map { m in "Mated (\(m.id)) to \(doc.project.displayName(of: m.a == ref ? m.b : m.a))" } ?? "Not mated")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func harnessSection(_ i: Int) -> some View {
        let inst = doc.project.harnesses[i]
        let a = doc.analysis.harnessAnalyses[inst.id]
        return Group {
            Section("Harness \(inst.id)") {
                TextField("Name", text: $doc.project.harnesses[i].harness.name)
                TextField("Revision", text: $doc.project.harnesses[i].harness.revision)
                Stepper("Quantity per system: \(inst.quantity)", value: $doc.project.harnesses[i].quantity, in: 0...100)
                Button("Open Harness Editor") { open(.harness(inst.id)) }
                Button("Duplicate") { doc.duplicateHarness(inst.id) }
                Button("Export as .loomo…") { doc.exportHarness(inst.id) }
            }
            Section("Contents") {
                LabeledContent("Connectors", value: "\(inst.harness.connectors.count)")
                LabeledContent("Wires", value: "\(inst.harness.wires.count)")
                LabeledContent("Errors", value: "\(a?.issues.filter { $0.severity == .error }.count ?? 0)")
            }
            Section("Connectors") {
                ForEach(inst.harness.connectors.filter { !$0.kind.isLooseTerminal }) { c in
                    let ref = ConnectorRef.harness(inst.id, connector: c.id)
                    LabeledContent(c.id + (c.name.isEmpty ? "" : " \(c.name)"),
                                   value: doc.project.mate(for: ref).map { m in doc.project.displayName(of: m.a == ref ? m.b : m.a) } ?? "not mated")
                }
            }
        }
    }

    private func mateSection(_ i: Int) -> some View {
        let m = doc.project.mates[i]
        let refs = doc.project.allConnectorRefs
        let pinsA = doc.project.pins(of: m.a) ?? []
        let pinsB = doc.project.pins(of: m.b) ?? []
        return Group {
            Section("Mate \(m.id)") {
                Picker("Side A", selection: $doc.project.mates[i].a) { ForEach(refs, id: \.self) { Text(doc.project.displayName(of: $0)).tag($0) } }
                Picker("Side B", selection: $doc.project.mates[i].b) { ForEach(refs, id: \.self) { Text(doc.project.displayName(of: $0)).tag($0) } }
                Button("Swap Sides") {
                    doc.perform("Swap Mate Sides") { p in
                        let x = p.mates[i]
                        p.mates[i].a = x.b
                        p.mates[i].b = x.a
                        p.mates[i].pinMap = Dictionary(x.pinMap.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
                    }
                }
            }
            Section("Pin map (A pin → B pin)") {
                ForEach(pinsA, id: \.label) { pa in
                    Picker("\(pa.label)\(pa.signal.map { "  \($0)" } ?? "")", selection: Binding(
                        get: { m.partner(ofA: pa.label) },
                        set: { v in doc.perform("Remap Pin \(pa.label)") { p in p.mates[i].pinMap[pa.label] = v == pa.label ? nil : v } })) {
                        ForEach(pinsB, id: \.label) { pb in Text(pb.label + (pb.signal.map { "  \($0)" } ?? "")).tag(pb.label) }
                        if !pinsB.contains(where: { $0.label == m.partner(ofA: pa.label) }) { Text("— (no partner)").tag(m.partner(ofA: pa.label)) }
                    }
                }
                if !m.pinMap.isEmpty { Button("Reset to 1:1") { doc.perform("Reset Pin Map") { $0.mates[i].pinMap = [:] } } }
            }
            Section {
                ForEach(doc.analysis.issues.filter { $0.subject == m.id }) { Text($0.message).font(.caption) }
                Button("Delete Mate", role: .destructive) { doc.deleteSelection() }
            }
        }
    }
}
