import Foundation
import Testing
@testable import CrimpCore

@Suite struct GroupEditTests {
    @Test func moveTogether() {
        var h = Harness.sample
        let origins = Dictionary(uniqueKeysWithValues: h.nodes.map { ($0.id, $0.position) })
        h.move(nodes: ["N4", "N5"], annotations: [], from: origins, by: 10, -20)
        #expect(h.node("N4")!.position == Point2D(origins["N4"]!.x + 10, origins["N4"]!.y - 20))
        #expect(h.node("N1")!.position == origins["N1"])
    }

    @Test func deletingNodesRemovesTheirItemsAndUnassignsWires() {
        var h = Harness.sample
        h.delete(["N4"])                     // C2's node
        #expect(h.connector("C2") == nil)
        #expect(h.segment("S3") == nil)
        #expect(h.wires.first { $0.id == "W1" }?.to == .unassigned)
        #expect(!h.coverings.contains { $0.segmentIDs.contains("S3") })
    }

    @Test func deleteMixedSelection() {
        var h = Harness.sample
        h.delete(["C3", "SP1", "L2", "W5"])
        #expect(h.connector("C3") == nil && h.splice("SP1") == nil)
        #expect(!h.labels.contains { $0.id == "L2" })
        #expect(h.wire("W5") == nil)
        #expect(h.wires.first { $0.id == "W2" }?.to == .unassigned)
    }

    @Test func splitSegmentKeepsTotalLengthAndCoverings() {
        var h = Harness.sample
        let n = h.splitSegment("S1", at: 0.5)!
        let parts = h.segments.filter { $0.nodeA == n || $0.nodeB == n }
        #expect(parts.map(\.lengthMM).reduce(0, +) == 600)
        #expect(h.coverings[0].segmentIDs.count == 3)
        #expect(HarnessAnalysis(h).routes["W1"]?.pathLengthMM == 1050)
    }

    @Test func placeConnectorUsesPartSpecs() {
        var h = Harness()
        var part = PartRef(mpn: "ABC-6F", manufacturer: "Acme")
        part.positionCount = 6
        part.contactGender = "Female"
        let id = h.placeConnector(part: part, at: Point2D(10, 10))
        #expect(h.connector(id)?.cavities.count == 6)
        #expect(h.connector(id)?.gender == .female)
        let cfg = PartLibrary.starter.parts.first { $0.part.mpn == "DT06-2S" }!
        let id2 = h.placeConnector(part: cfg.part, at: Point2D(50, 10), configuration: cfg)
        #expect(h.connector(id2)?.cavities.count == 2)
        #expect(h.connector(id2)?.accessories.first?.part.mpn == "W2S")
    }
}

@Suite struct PriceRefreshTests {
    @Test func updatesEveryReferenceByNormalisedMPN() {
        var h = Harness.sample
        #expect(h.purchasableMPNs.contains("DT06-4S"))
        #expect(!h.purchasableMPNs.contains("GENERIC"))
        let n = h.updatePrices(["dt064s": 1.57, "0462201-16141": 0.31])
        #expect(n == 4)    // housing + 3 socket contacts
        #expect(h.connector("C1")?.part?.unitPrice == 1.57)
        #expect(h.connector("C1")?.cavities[0].terminal?.unitPrice == 0.31)
        #expect(abs((HarnessAnalysis(h).bom.first { $0.mpn == "0462-201-16141" }?.extendedPrice ?? 0) - 0.93) < 1e-9)
    }
}

@Suite struct LibraryMatchTests {
    @Test func matchesDistributorSpellingOfManufacturer() {
        let lib = PartLibrary.starter
        #expect(lib.entry(for: PartRef(mpn: "DT06-4S", manufacturer: "TE Connectivity"))?.related.count == 3)
        #expect(lib.entry(for: PartRef(mpn: "dt064s", manufacturer: "Deutsch"))?.part.mpn == "DT06-4S")
        #expect(lib.entry(for: PartRef(mpn: "DT06-4S", manufacturer: "Acme")) == nil)
    }
}
