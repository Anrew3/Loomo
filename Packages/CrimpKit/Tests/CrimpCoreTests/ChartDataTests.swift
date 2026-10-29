import Foundation
import Testing
@testable import CrimpCore

@Suite struct ChartDataTests {
    let h = Harness.sample
    var a: HarnessAnalysis { HarnessAnalysis(h) }

    @Test func wireLengthsAddUpToTheCutList() {
        let bars = ChartData.wireLengthBySize(h, analysis: a)
        let total = a.cutList.compactMap(\.cutLengthMM).reduce(0, +)
        #expect(abs(bars.map(\.value).reduce(0, +) - total) < 0.01)
        // Thickest size first: the sample uses 18 AWG and 20 AWG.
        #expect(bars.first?.label == "18 AWG")
    }

    @Test func partCountsSkipLengths() {
        let bars = ChartData.partsByCategory(a.bom)
        #expect(!bars.isEmpty)
        #expect(!bars.contains { $0.label == "Wire" })
        #expect(zip(bars, bars.dropFirst()).allSatisfy { $0.value >= $1.value })
    }

    @Test func costNeedsPrices() {
        #expect(ChartData.costByCategory(a.bom.map { var l = $0; l.unitPrice = nil; return l }).isEmpty)
        var priced = a.bom
        if let i = priced.firstIndex(where: { $0.unit == .each }) { priced[i].unitPrice = 2 }
        #expect(ChartData.costByCategory(priced).count == 1)
    }

    @Test func everyBundleHasADiameter() {
        let bars = ChartData.bundleDiameters(h, analysis: a)
        #expect(bars.count == h.segments.count)
        #expect(bars.allSatisfy { $0.value > 0 && $0.label.contains("–") })
    }
}
