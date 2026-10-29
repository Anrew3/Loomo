import Testing
@testable import CrimpCore

@Suite struct AnalysisTests {
    let h = Harness.sample
    var a: HarnessAnalysis { HarnessAnalysis(h) }

    @Test func wireLengthFollowsTopologyPlusAllowances() {
        // C1 → C2: S1 600 + S2 150 + S3 300 = 1050, plus 2 × 20 allowance.
        let route = a.routes["W1"]!
        #expect(route.segmentIDs == ["S1", "S2", "S3"])
        #expect(route.pathLengthMM == 1050)
        #expect(route.lengthMM == 1090)
    }

    @Test func spliceEndRoutesFromSpliceNode() {
        // SP1 sits on N2, so W4 runs S2 + S4.
        #expect(a.routes["W4"]?.pathLengthMM == 600)
    }

    @Test func overrideWins() {
        var h2 = h
        h2.wires[0].lengthOverrideMM = 1234
        let r = HarnessAnalysis(h2).routes["W1"]!
        #expect(r.lengthMM == 1234)
        #expect(r.isOverridden)
    }

    @Test func trunkCarriesEveryWireLeavingX1() {
        #expect(Set(a.segmentWires["S1"] ?? []) == ["W1", "W2", "W5"])
        #expect(a.bundleDiameterMM["S1"]! > 2.5)
    }

    @Test func bomCountsTerminalsSealsAndPlugs() {
        let bom = a.bom
        #expect(bom.first { $0.mpn == "0462-201-16141" }?.quantity == 3)
        #expect(bom.first { $0.mpn == "114017" }?.quantity == 1)
        // C2 uses cavities 1–2, C3 uses 2–3 → 4 seals.
        #expect(bom.first { $0.mpn == "SAMPLE-SEAL-1.4" }?.quantity == 4)
    }

    @Test func sealedConnectorUnusedCavityNeedsPlug() {
        let msgs = a.issues.filter { $0.subject == "C2" }.map(\.message)
        #expect(msgs.contains { $0.contains("cavity 3") && $0.contains("plug") })
    }

    @Test func halfLapTapeUsesMoreThanSegmentLength() {
        let tape = h.coverings.first { $0.kind == .tape }!
        let qty = HarnessAnalysis.coveringQuantityMM(tape, in: h, bundle: a.bundleDiameterMM)
        // Two-wire branches: Ø≈2.2 mm, pitch 9.5 mm → ≈1.24 mm of tape per mm, plus 5 % margin.
        #expect(qty > 750 * 1.2)
        #expect(qty < 750 * 1.5)
    }

    @Test func undersizedTubeIsFlagged() {
        var h2 = h
        h2.coverings[0].innerDiameterMM = 2
        #expect(HarnessAnalysis(h2).issues.contains { $0.subject == "CV1" && $0.severity == .error })
    }

    @Test func roundTripsThroughJSON() throws {
        #expect(try Harness.load(from: h.jsonData()) == h)
    }

    @Test func wireVizExportHasConnections() {
        let yaml = WireVizExport.yaml(for: h)
        #expect(yaml.contains("connections:"))
        #expect(yaml.contains("- C1: [1]"))
        #expect(yaml.contains("colors: [GNWH]"))
    }
}
