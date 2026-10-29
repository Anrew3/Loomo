import Foundation

/// One bar in a chart: a label, a value, and the text shown when it is hovered.
public struct ChartBar: Identifiable, Hashable, Sendable {
    public var id: String { label }
    public var label: String
    public var value: Double

    public init(label: String, value: Double) {
        self.label = label
        self.value = value
    }
}

/// The numbers behind the charts on the BOM, cut list and summary pages. Largest first.
public enum ChartData {
    /// Extended cost per BOM category, from lines that have a price; empty when nothing is priced.
    public static func costByCategory(_ bom: [BOMLine]) -> [ChartBar] {
        let sums = Dictionary(grouping: bom.compactMap { l in l.extendedPrice.map { (l.category, $0) } }, by: \.0)
            .mapValues { $0.reduce(0) { $0 + $1.1 } }
        return sums.filter { $0.value > 0 }.map { ChartBar(label: $0.key, value: $0.value) }.sorted(by: largestFirst)
    }

    /// Number of pieces per BOM category (lines counted in "each"; wire and tubing are lengths, not pieces).
    public static func partsByCategory(_ bom: [BOMLine]) -> [ChartBar] {
        let sums = Dictionary(grouping: bom.filter { $0.unit == .each }, by: \.category).mapValues { $0.reduce(0) { $0 + $1.quantity } }
        return sums.filter { $0.value > 0 }.map { ChartBar(label: $0.key, value: $0.value) }.sorted(by: largestFirst)
    }

    /// Total cut length (mm) per wire size, thickest size first.
    public static func wireLengthBySize(_ h: Harness, analysis: HarnessAnalysis) -> [ChartBar] {
        var total: [String: Double] = [:], area: [String: Double] = [:]
        for row in analysis.cutList {
            guard let mm = row.cutLengthMM, mm > 0, !row.size.isEmpty else { continue }
            total[row.size, default: 0] += mm
            if let w = h.wire(row.wireID) { area[row.size] = w.size.crossSectionMM2 }
        }
        return total.map { ChartBar(label: $0.key, value: $0.value) }
            .sorted { (area[$0.label] ?? 0, $0.value) > (area[$1.label] ?? 0, $1.value) }
    }

    /// Bundle diameter (mm) per segment, labelled with the segment and what it joins; widest first.
    public static func bundleDiameters(_ h: Harness, analysis: HarnessAnalysis) -> [ChartBar] {
        func end(_ n: EntityID) -> String {
            if let c = h.connectors.first(where: { $0.nodeID == n }) { return c.id }
            let s = h.splices.filter { $0.nodeID == n }.map(\.id)
            return s.isEmpty ? n : s.joined(separator: "/")
        }
        return h.segments.compactMap { s in
            guard let d = analysis.bundleDiameterMM[s.id], d > 0 else { return nil }
            return ChartBar(label: "\(s.id) \(end(s.nodeA))–\(end(s.nodeB))", value: d)
        }
        .sorted(by: largestFirst)
    }

    private static func largestFirst(_ a: ChartBar, _ b: ChartBar) -> Bool {
        a.value != b.value ? a.value > b.value : a.label < b.label
    }
}
