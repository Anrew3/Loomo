import CoreGraphics
import Foundation
import Testing
@testable import CrimpCore
@testable import CrimpOutputs

@Suite struct SystemTests {
    let p = SystemProject.sample
    var a: SystemAnalysis { SystemAnalysis(p) }

    @Test func netsCrossHarnessesThroughMates() {
        // 5V: ECU/J1:1 → H1 W1 → H1/C2:1 ⇄ H2/P1:1 → H2 W1 → H2/P2:1 ⇄ SNS/J1:1
        let net = a.nets.first { $0.name == "5V" }!
        #expect(net.devicePins == ["ECU/J1:1", "SNS/J1:1"])
        #expect(net.wires == ["H1/W1", "H2/W1"])
        #expect(net.harnesses == ["H1", "H2"])
    }

    @Test func groundJoinsThroughSpliceAndMates() {
        let gnd = a.nets.first { $0.name == "GND" }!
        #expect(gnd.devicePins == ["ECU/J1:2", "SNS/J1:2"])
        #expect(gnd.pins.contains("H1/C4:1"))        // ring terminal on the splice
        #expect(gnd.wires.contains("H1/W6") && gnd.wires.contains("H2/W2"))
    }

    @Test func traceFollowsWiresAndMates() {
        let steps = a.trace(from: "ECU/J1:1")
        #expect(steps.first?.via == .mate("M1"))
        #expect(steps.contains { $0.to == "SNS/J1:1" })
        #expect(steps.contains { $0.via == .wire(harness: "H2", wire: "W1") })
        let depth = steps.first { $0.to == "SNS/J1:1" }!.depth
        #expect(depth == 5)
    }

    @Test func splitDeviceSignalIsAnOpenCircuitWarning() {
        // The jumper does not carry SIG_A, so the sensor's SIG_A pin is on its own net.
        #expect(a.issues.contains { $0.subject == "SIG_A" && $0.message.hasPrefix("Open circuit") })
        #expect(!a.nets.contains { $0.name.hasPrefix("NET") && $0.wires.isEmpty })
    }

    @Test func shortBetweenDeviceSignalsIsAnError() {
        var q = p
        // Swap the jumper's 5V and GND wires at P2 — 5V now lands on the sensor's GND pin.
        q.harnesses[1].harness.wires[0].to = .pin(connector: "P2", cavity: "2")
        q.harnesses[1].harness.wires[1].to = .pin(connector: "P2", cavity: "1")
        let issues = SystemAnalysis(q).issues
        #expect(issues.contains { $0.severity == .error && $0.message.hasPrefix("Short") })
    }

    @Test func mateRules() {
        var q = p
        q.mates.append(Mate(id: "M9", a: .harness("H1", connector: "C1"), b: .harness("H2", connector: "P2")))
        let issues = SystemAnalysis(q).issues
        #expect(issues.contains { $0.subject == "H1/C1" && $0.message.contains("mated 2 times") })
        #expect(issues.contains { $0.subject == "M9" && $0.message.contains("both female") })
        #expect(issues.contains { $0.subject == "M9" && $0.message.contains("no partner") })  // C1 has 4 pins, P2 has 3
        #expect(SystemAnalysis(p).issues.contains { $0.subject == "H1/C3" && $0.message.contains("not mated") })
    }

    @Test func pinMapRemapsMatedPins() {
        var q = p
        q.mates[2].pinMap = ["1": "2", "2": "1"]
        #expect(SystemAnalysis(q).issues.contains { $0.message.hasPrefix("Short") })
    }

    @Test func systemBOMMultipliesQuantities() {
        var q = p
        q.harnesses[1].quantity = 3
        let line = SystemAnalysis(q).bom.first { $0.line.category == "Connector" && $0.line.mpn == "DT06-4S" }!
        #expect(line.line.quantity == 1)
        let jumperWire = SystemAnalysis(q).bom.first { $0.line.category == "Wire" && $0.breakdown["H2"] != nil }!
        let single = SystemAnalysis(p).bom.first { $0.id == jumperWire.id }!
        #expect(jumperWire.breakdown["H2"]! == 3 * single.breakdown["H2"]!)
    }

    @Test func autoMateByName() {
        var q = p
        q.mates = []
        q.devices[0].connectors[0].name = "Main"     // H1/C1 is named "Main"
        #expect(q.autoMateByName() >= 1)
        #expect(q.mate(for: .harness("H1", connector: "C1"))?.b == .device("ECU", connector: "J1"))
    }

    @Test func matingDeviceConnectorCopiesPins() {
        var q = p
        let ref = q.addMatingDeviceConnector(for: .harness("H1", connector: "C3"), on: "SNS")!
        #expect(q.pins(of: ref)?.count == 3)
        #expect(q.gender(of: ref) == .male)
        #expect(q.mate(for: ref) != nil)
    }

    @Test func layoutPortsAndHitTesting() {
        let l = SystemLayout(p)
        let (left, right) = l.ports(.device("ECU", connector: "J1"))!
        #expect(right.x - left.x == SystemLayout.blockWidth)
        #expect(l.hitRow(CGPoint(x: left.x + 20, y: left.y)) == .device("ECU", connector: "J1"))
        let (a, b) = l.line(p.mates[0])!
        #expect(l.hitMate(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), mates: p.mates) == "M1")
    }

    @Test func roundTripsAndExports() throws {
        #expect(try SystemProject.load(from: p.encoded()) == p)
        let pdf = SystemPDF.make(p)
        let pages = CGPDFDocument(CGDataProvider(data: pdf as CFData)!)!.numberOfPages
        #expect(pages > 5 + 2 * DrawingPage.allCases.count - 1)
        #expect(!SystemAnalysis(p).workbook(for: p).data().isEmpty)
    }
}
