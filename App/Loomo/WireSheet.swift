import CrimpCore
import SwiftUI

/// A request to open the New Wire sheet, optionally with one or both ends chosen (connector or splice ids).
struct WireRequest: Identifiable {
    let id = UUID()
    var from: EntityID?
    var to: EntityID?
}

/// Connects two ends with a wire. Each end is a connector cavity (picked on an even grid) or a splice.
/// Choosing a cavity that already has a wire offers a double crimp. "Add & Next" keeps the sheet open.
struct NewWireSheet: View {
    @ObservedObject var doc: HarnessDocument
    let request: WireRequest

    @State private var fromItem: EntityID = ""
    @State private var toItem: EntityID = ""
    @State private var fromCavity: String?
    @State private var toCavity: String?
    @State private var signal = ""
    @State private var addBundle = true
    @State private var doubleCrimp = false
    @State private var added: [EntityID] = []
    @AppStorage("newWire.size") private var sizeTag = "awg20"
    @AppStorage("newWire.color") private var colorBase = "BK"
    @AppStorage("newWire.stripe") private var stripe = ""
    @AppStorage("newWire.insulation") private var insulation = "TXL"
    @Environment(\.dismiss) private var dismiss

    private static let colors = WireTables.colorOrder
    private static let awg = [26, 24, 22, 20, 18, 16, 14, 12, 10, 8]
    private static let mm2 = [0.35, 0.5, 0.75, 1.0, 1.5, 2.5, 4.0, 6.0]
    static let cell: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                IconTile(systemName: Pane.wires.icon, tint: Pane.wires.tint, size: 34)
                Text("New Wire").font(.title2.weight(.semibold))
                Spacer()
                if !added.isEmpty { Text("Added \(added.joined(separator: ", "))").font(.callout).foregroundStyle(.green) }
            }
            if doc.harness.connectors.isEmpty && doc.harness.splices.isEmpty {
                ContentUnavailableView("Nothing to connect yet", systemImage: "powerplug",
                                       description: Text("Right-click the drawing to place connectors or splices first."))
            } else {
                HStack(alignment: .top, spacing: 16) {
                    endColumn(title: "From", item: $fromItem, cavity: $fromCavity)
                    Image(systemName: "arrow.right").font(.title2).foregroundStyle(.secondary).padding(.top, 40)
                    endColumn(title: "To", item: $toItem, cavity: $toCavity)
                }
                specRow
                if sharedCavity != nil {
                    Toggle("Double crimp: two wires in one terminal at \(sharedCavity!.description)", isOn: $doubleCrimp)
                        .font(.callout)
                }
                if let a = fromEndpoint, let b = toEndpoint, !doc.harness.hasRoute(a, b),
                   let na = HarnessAnalysis.node(for: a, in: doc.harness), let nb = HarnessAnalysis.node(for: b, in: doc.harness), na != nb {
                    Toggle("Add a bundle segment between \(fromItem) and \(toItem) so the wire length can be calculated", isOn: $addBundle)
                        .font(.callout)
                }
                if let warning { Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            }
            HStack {
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(added.isEmpty ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add & Next") { add(next: true) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canAdd)
                    .help("Adds the wire and moves connector ends to the next free cavity (⌘↩)")
                Button("Add Wire") { add(next: false) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 820)
        .onAppear(perform: setUp)
        .onChange(of: sharedCavity) { doubleCrimp = sharedCavity != nil }
    }

    // MARK: Ends

    private func endpoint(_ item: EntityID, _ cavity: String?) -> Endpoint? {
        if doc.harness.splice(item) != nil { return .splice(item) }
        guard doc.harness.connector(item) != nil, let cavity else { return nil }
        return .pin(connector: item, cavity: cavity)
    }

    private var fromEndpoint: Endpoint? { endpoint(fromItem, fromCavity) }
    private var toEndpoint: Endpoint? { endpoint(toItem, toCavity) }

    /// A chosen connector cavity that already holds a wire.
    private var sharedCavity: Endpoint? {
        [fromEndpoint, toEndpoint].compactMap { $0 }.first { e in
            if case .pin = e { return doc.harness.isOccupied(e) }
            return false
        }
    }

    private func endColumn(title: String, item: Binding<EntityID>, cavity: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Picker(title, selection: item) {
                if !doc.harness.connectors.isEmpty {
                    Section("Connectors") {
                        ForEach(doc.harness.connectors) { c in
                            Text([c.id, c.name, c.part?.mpn].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).tag(c.id)
                        }
                    }
                }
                if !doc.harness.splices.isEmpty {
                    Section("Splices") {
                        ForEach(doc.harness.splices) { s in Text("\(s.id) · \(s.kind.title)").tag(s.id) }
                    }
                }
            }
            .labelsHidden()
            .onChange(of: item.wrappedValue) { cavity.wrappedValue = doc.harness.firstFreeCavity(item.wrappedValue) }
            if let c = doc.harness.connector(item.wrappedValue) {
                HStack(alignment: .top, spacing: 8) {
                    PartPhoto(url: c.part.flatMap(LibraryStore.shared.photoURL), size: 44)
                    cavityGrid(c, selection: cavity)
                }
            } else if let s = doc.harness.splice(item.wrappedValue) {
                let n = doc.harness.wireEnds(at: .splice(s.id)).count
                Label("\(s.kind.title) · \(n) wire\(n == 1 ? "" : "s") joined", systemImage: "arrow.triangle.merge")
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Even cells, at most six per row, rows balanced (8 → 4 + 4, 7 → 4 + 3).
    static func columns(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        let rows = Int((Double(count) / 6).rounded(.up))
        return Int((Double(count) / Double(rows)).rounded(.up))
    }

    private func cavityGrid(_ c: Connector, selection: Binding<String?>) -> some View {
        let cols = Self.columns(for: c.cavities.count)
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: 6), count: cols), alignment: .leading, spacing: 6) {
            ForEach(c.cavities, id: \.label) { cav in
                let here = Endpoint.pin(connector: c.id, cavity: cav.label)
                let cavityWires = doc.harness.wires.filter { $0.from == here || $0.to == here }
                let selected = selection.wrappedValue == cav.label
                Button { selection.wrappedValue = cav.label } label: {
                    VStack(spacing: 2) {
                        Text(cav.label).font(.caption.bold())
                        ZStack {
                            Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 18, height: 18)
                            if let w = cavityWires.first { WireDot(color: w.color).frame(width: 14, height: 14) }
                            else if cav.plug != nil { Circle().fill(.gray.opacity(0.5)).frame(width: 12, height: 12) }
                            if cavityWires.count > 1 {
                                Text("\(cavityWires.count)").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                                    .padding(2).background(.orange, in: Circle()).offset(x: 9, y: -8)
                            }
                        }
                        Text(cavityWires.map(\.id).joined(separator: ",").nonEmpty ?? cav.signal ?? " ")
                            .font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                    }
                    .frame(width: Self.cell, height: 58)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.3) : Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help(cavityWires.isEmpty ? (cav.plug != nil ? "Plugged; the plug is removed when a wire is added" : "Free")
                                          : "\(cavityWires.map(\.id).joined(separator: ", ")) already here; choosing it makes a double crimp")
            }
        }
        .fixedSize()
    }

    // MARK: Spec

    private var specRow: some View {
        HStack(spacing: 12) {
            TextField("Signal", text: $signal, prompt: Text(defaultSignal ?? "Signal (optional)")).frame(width: 150)
            Picker("Size", selection: $sizeTag) {
                Section("AWG") { ForEach(Self.awg, id: \.self) { Text("\($0) AWG").tag("awg\($0)") } }
                Section("Metric") { ForEach(Self.mm2, id: \.self) { Text(String(format: "%g mm²", $0)).tag("mm\($0)") } }
            }
            .fixedSize()
            HStack(spacing: 4) {
                WireDot(color: WireColor(colorBase, stripe: stripe.isEmpty ? nil : stripe)).frame(width: 16, height: 16)
                Picker("Colour", selection: $colorBase) { ForEach(Self.colors, id: \.self) { Text(colorLabel($0)).tag($0) } }.fixedSize()
                Picker("Stripe", selection: $stripe) {
                    Text("None").tag("")
                    ForEach(Self.colors, id: \.self) { Text(colorLabel($0)).tag($0) }
                }
                .fixedSize()
            }
            Picker("Insulation", selection: $insulation) {
                ForEach(["TXL", "GXL", "SXL", "PTFE", "ETFE", "XLPE", "PVC", "Silicone"], id: \.self) { Text($0).tag($0) }
            }
            .fixedSize()
        }
    }

    private var size: WireSize {
        if sizeTag.hasPrefix("awg"), let n = Int(sizeTag.dropFirst(3)) { return .awg(n) }
        if sizeTag.hasPrefix("mm"), let v = Double(sizeTag.dropFirst(2)) { return WireSize(mm2: v) }
        return .awg(20)
    }

    private var defaultSignal: String? {
        [fromEndpoint, toEndpoint].compactMap { $0 }.compactMap { doc.harness.cavity($0)?.signal }.first
    }

    // MARK: Validation and adding

    private var canAdd: Bool {
        guard let a = fromEndpoint, let b = toEndpoint else { return false }
        return a != b
    }

    private var warning: String? {
        guard let a = fromEndpoint, let b = toEndpoint else { return "Choose a cavity (or a splice) at each end." }
        if a == b { return "Both ends are the same." }
        if let shared = sharedCavity, !doubleCrimp { return "\(shared) already has a wire; turn on Double crimp if the terminal takes two." }
        return nil
    }

    private var summary: String {
        guard let a = fromEndpoint, let b = toEndpoint else { return "" }
        let color = WireColor(colorBase, stripe: stripe.isEmpty ? nil : stripe)
        return "\(doc.harness.nextID(prefix: "W")): \(a) → \(b), \(size) \(color) \(insulation)"
    }

    private func setUp() {
        let ids = doc.harness.connectors.map(\.id) + doc.harness.splices.map(\.id)
        fromItem = request.from ?? ids.first ?? ""
        toItem = request.to ?? ids.first { $0 != fromItem } ?? fromItem
        fromCavity = doc.harness.firstFreeCavity(fromItem)
        toCavity = doc.harness.firstFreeCavity(toItem)
        if fromItem == toItem, let f = fromCavity { toCavity = doc.harness.firstFreeCavity(toItem, after: f) }
    }

    private func add(next: Bool) {
        guard let a = fromEndpoint, let b = toEndpoint, a != b else { return }
        let color = WireColor(colorBase, stripe: stripe.isEmpty ? nil : stripe)
        var id = ""
        doc.perform("Add Wire \(a) → \(b)") { h in
            id = h.connect(a, b, size: size, color: color, signal: signal.isEmpty ? nil : signal,
                           insulation: insulation, addBundleIfMissing: addBundle, doubleCrimp: doubleCrimp)
        }
        added.append(id)
        signal = ""
        if next {
            if doc.harness.connector(fromItem) != nil { fromCavity = doc.harness.firstFreeCavity(fromItem, after: fromCavity) }
            if doc.harness.connector(toItem) != nil { toCavity = doc.harness.firstFreeCavity(toItem, after: toCavity) }
        } else {
            doc.multiSelection = []
            doc.selection = .wire(id)
            dismiss()
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// "LB  Light blue" for colour pickers.
func colorLabel(_ code: String) -> String {
    WireTables.colorTitles[code].map { "\(code)  \($0)" } ?? code
}
