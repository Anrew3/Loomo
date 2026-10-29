import Foundation
import Testing
@testable import CrimpCore

struct WireVizImportTests {
    // In the style of WireViz's own tutorial files.
    let yaml = """
    metadata:
      title: Serial cable # a comment
    connectors:
      X1:
        type: D-Sub
        subtype: female
        pinlabels: [DCD, RX, TX, DTR, GND, DSR, RTS, CTS, RI]
      X2:
        type: Molex KK 254
        subtype: female
        mpn: "22-01-3047"
        manufacturer: Molex
        pinlabels: [GND, RX, TX]
    cables:
      W1:
        gauge: 0.25 mm2
        length: 0.2
        colors: [WH, BN, GNYE]
    connections:
      -
        - X1: [5, 2, 3]
        - W1: [1-3]
        - X2: [1, 3, 2]
    """

    @Test func readsConnectorsAndWires() throws {
        let (h, report) = try WireVizImport.harness(fromYAML: yaml)
        #expect(h.name == "Serial cable")
        #expect(report.connectors == 2)
        #expect(report.wires == 3)
        #expect(report.skipped.isEmpty)
        let x1 = try #require(h.connector("X1"))
        #expect(x1.cavities.count == 9)
        #expect(x1.gender == .female)
        #expect(x1.cavities.first { $0.label == "5" }?.signal == "GND")
        #expect(h.connector("X2")?.part?.mpn == "22-01-3047")
        let gnd = try #require(h.wires.first { $0.from == .pin(connector: "X1", cavity: "5") })
        #expect(gnd.to == .pin(connector: "X2", cavity: "1"))
        #expect(gnd.color.base == "WH")
        #expect(abs(gnd.size.crossSectionMM2 - 0.25) < 0.001)
        let tx = try #require(h.wires.first { $0.from == .pin(connector: "X1", cavity: "3") })
        #expect(tx.color == WireColor("GN", stripe: "YE"))
    }

    @Test func roundTripsLoomosExport() throws {
        let original = Harness.sample
        let (h, report) = try WireVizImport.harness(fromYAML: WireVizExport.yaml(for: original))
        #expect(report.connectors == original.connectors.count, "\(report.skipped)")
        #expect(report.splices == original.splices.count)
        let assigned = original.wires.filter { $0.from != .unassigned && $0.to != .unassigned }
        #expect(h.wires.count == assigned.count, "\(report.skipped)")
    }
}
