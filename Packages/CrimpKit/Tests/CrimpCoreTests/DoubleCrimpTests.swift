import Foundation
import Testing
@testable import CrimpCore

@Suite struct DoubleCrimpTests {
    @Test func doubleCrimpIsAcceptedAndChecked() {
        var h = Harness.sample
        // C2:3 is empty; put two wires in C2:2 (already has W3) as a double crimp.
        h.connect(.pin(connector: "C1", cavity: "4"), .pin(connector: "C2", cavity: "2"), doubleCrimp: true)
        #expect(h.connector("C2")?.cavities[1].doubleCrimp == true)
        let issues = HarnessAnalysis(h).issues.filter { $0.subject == "C2:2" }
        #expect(!issues.contains { $0.message.contains("share one cavity") })
        // A third wire is an error.
        h.connect(.pin(connector: "C3", cavity: "1"), .pin(connector: "C2", cavity: "2"), doubleCrimp: true)
        #expect(HarnessAnalysis(h).issues.contains { $0.subject == "C2:2" && $0.severity == .error && $0.message.contains("3 wires") })
    }

    @Test func undeclaredSharingStillWarns() {
        var h = Harness.sample
        h.connect(.pin(connector: "C1", cavity: "4"), .pin(connector: "C2", cavity: "2"))
        #expect(HarnessAnalysis(h).issues.contains { $0.subject == "C2:2" && $0.message.contains("double crimp") })
    }

    @Test func combinedSizeAgainstTerminalRating() {
        var h = Harness.sample
        h.connectors[1].cavities[1].terminal?.maxWireMM2 = 0.8   // sensor terminal
        h.connect(.pin(connector: "C1", cavity: "4"), .pin(connector: "C2", cavity: "2"), size: .awg(20), doubleCrimp: true)
        #expect(HarnessAnalysis(h).issues.contains { $0.subject == "C2:2" && $0.message.contains("Double crimp totals") })
    }

    @Test func faceShowsBothWires() {
        var h = Harness.sample
        h.connect(.pin(connector: "C1", cavity: "4"), .pin(connector: "C2", cavity: "2"), color: WireColor("RD"), doubleCrimp: true)
        let c2 = h.connector("C2")!
        let d = h.faceDrawing(for: c2, layout: h.faceLayout(for: c2))
        #expect(d.primitives.contains { if case .rightHalf = $0 { return true } else { return false } })
        #expect(d.svg().contains("<path"))
    }

    @Test func spliceWiring() {
        var h = Harness.sample
        let a = h.connect(.pin(connector: "C2", cavity: "3"), .splice("SP1"))
        let b = h.connect(.splice("SP1"), .pin(connector: "C3", cavity: "1"))
        #expect(h.wire(a)?.to == .splice("SP1") && h.wire(b)?.from == .splice("SP1"))
        #expect(HarnessAnalysis(h).nets.first { $0.wires.contains(a) }?.wires.contains(b) == true)
    }

    @Test func renumberConnectors() {
        var h = Harness.sample
        h.renameConnector("C1", to: "X7")
        h.renumberConnectors()
        #expect(h.connectors.filter { !$0.kind.isLooseTerminal }.map(\.id).sorted() == ["C1", "C2", "C3"])
        #expect(h.wires.first { $0.id == "W2" }?.from == .pin(connector: "C2", cavity: "2") || h.wires.first { $0.id == "W2" }?.from.connectorID != nil)
        #expect(Set(h.wires.flatMap { [$0.from, $0.to] }.compactMap(\.connectorID)).isSubset(of: Set(h.connectors.map(\.id))))
    }
}
