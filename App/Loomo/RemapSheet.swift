import CrimpCore
import SwiftUI

struct RemapRequest: Identifiable {
    var id: EntityID { from }
    var from: EntityID
}

/// Moves every wire end from one connector to another, cavity by cavity, with a preview of what won't fit.
/// For when a design changes: a connector is replaced by a different one, or two drawings are merged.
struct RemapSheet: View {
    @ObservedObject var doc: HarnessDocument
    let request: RemapRequest
    @Environment(\.dismiss) private var dismiss
    @State private var target: EntityID = ""
    @State private var map: [String: String] = [:]
    @State private var byOrder = false

    private var source: Connector? { doc.harness.connector(request.from) }
    private var dest: Connector? { doc.harness.connector(target) }

    /// Cavities on the source that carry a wire, in label order.
    private var usedCavities: [String] {
        guard let c = source else { return [] }
        let used = Set(doc.harness.wires.flatMap { [$0.from, $0.to] }.compactMap { e -> String? in
            if case let .pin(cid, cav) = e, cid == c.id { return cav }
            return nil
        })
        return c.cavities.map(\.label).filter(used.contains)
    }

    private func mapped(_ cav: String) -> String {
        if let m = map[cav] { return m }
        if byOrder, let s = source, let d = dest, let i = s.cavities.firstIndex(where: { $0.label == cav }), i < d.cavities.count {
            return d.cavities[i].label
        }
        return cav
    }

    var body: some View {
        let targets = doc.harness.connectors.filter { $0.id != request.from && $0.kind != .device }
        VStack(alignment: .leading, spacing: 14) {
            Text("Remap connections from \(request.from)").font(.title3.weight(.semibold))
            Text("Every wire on \(request.from) moves to the connector you choose. Pick the cavity each one lands in; unmatched ones are listed before anything changes.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("Move wires to", selection: $target) {
                    Text("Choose a connector").tag("")
                    ForEach(targets) { c in Text([c.id, c.name, c.part?.mpn ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).tag(c.id) }
                }
                Picker("Match cavities", selection: $byOrder) {
                    Text("By label (2 → 2)").tag(false)
                    Text("By position (2nd → 2nd)").tag(true)
                }
                .onChange(of: byOrder) { map = [:] }
            }
            .formStyle(.grouped)
            .frame(height: 120)
            if let d = dest {
                Table(usedCavities.map(Row.init)) {
                    TableColumn("From \(request.from)") { row in fromCell(row.id) }
                    TableColumn("To \(d.id)") { row in toCell(row.id, d) }
                    TableColumn("") { row in warning(row.id, d) }
                }
                .frame(minHeight: 180)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move \(usedCavities.count) Wire End\(usedCavities.count == 1 ? "" : "s")") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(dest == nil || usedCavities.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    private struct Row: Identifiable { let id: String }

    private func wire(on cav: String) -> Wire? {
        doc.harness.wires.first { $0.from == .pin(connector: request.from, cavity: cav) || $0.to == .pin(connector: request.from, cavity: cav) }
    }

    @ViewBuilder private func fromCell(_ cav: String) -> some View {
        let w = wire(on: cav)
        HStack(spacing: 6) {
            if let w { WireDot(color: w.color).frame(width: 11, height: 11) }
            Text(cav + "  " + (w.map { HarnessAnalysis.conductorName($0) } ?? ""))
        }
    }

    private func toCell(_ cav: String, _ d: Connector) -> some View {
        let current = mapped(cav)
        let labels = d.cavities.map(\.label)
        return Picker("", selection: Binding(get: { current }, set: { map[cav] = $0 })) {
            ForEach(labels, id: \.self) { Text($0).tag($0) }
            if !labels.contains(current) { Text("\(current) (missing)").tag(current) }
        }
        .labelsHidden()
    }

    @ViewBuilder private func warning(_ cav: String, _ d: Connector) -> some View {
        let target = mapped(cav)
        if !d.cavities.contains(where: { $0.label == target }) {
            Label("No such cavity on \(d.id)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        } else if usedCavities.filter({ mapped($0) == target }).count > 1 {
            Label("Two wires land here", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        }
    }

    private func apply() {
        let cavityMap = Dictionary(uniqueKeysWithValues: usedCavities.map { ($0, mapped($0)) })
        doc.perform("Remap \(request.from) → \(target)") { h in
            h.remapConnections(from: request.from, to: target, cavityMap: cavityMap)
        }
        doc.selection = .connector(target)
        dismiss()
    }
}
