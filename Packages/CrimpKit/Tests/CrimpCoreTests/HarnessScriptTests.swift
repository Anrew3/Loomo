import Foundation
import Testing
@testable import CrimpCore

@Suite struct HarnessScriptTests {
    @Test func parsesLengthsSizesAndColours() throws {
        #expect(try HarnessScript.length("6in") == 152.4)
        #expect(try HarnessScript.length("150") == 150)
        #expect(try HarnessScript.wireSize("18 AWG").awg == 18)
        #expect(try HarnessScript.wireSize("0.5mm²").crossSectionMM2 == 0.5)
        #expect(try HarnessScript.wireColor("red/white") == WireColor("RD", stripe: "WH"))
        #expect(throws: EditError.self) { try HarnessScript.wireColor("plaid") }
        #expect(throws: EditError.self) { try HarnessScript.length("far") }
    }

    @Test func buildsAHarnessFromText() throws {
        var h = Harness()
        let c1 = try HarnessScript.addConnector(.init(mpn: "DT06-2S", manufacturer: "TE", cavities: 2), part: PartRef(mpn: "DT06-2S", manufacturer: "TE"), config: nil, to: &h)
        let sp = h.addSplice(at: Point2D(400, 240))
        try HarnessScript.addWire(from: "\(c1):1", to: sp, size: "18awg", color: "red", signal: "12V", in: &h)
        #expect(h.wires.count == 1)
        #expect(h.segments.count == 1)   // a bundle was added so the wire has a length
        // A second wire into the same cavity needs the double-crimp flag.
        #expect(throws: EditError.self) { try HarnessScript.addWire(from: "\(c1):1", to: sp, in: &h) }
        try HarnessScript.addWire(from: "\(c1):1", to: sp, doubleCrimp: true, in: &h)
        #expect(h.wires.count == 2)
        // Unknown cavities are explained, not crashed on.
        #expect(throws: EditError.self) { try HarnessScript.addWire(from: "\(c1):9", to: sp, in: &h) }
    }

    @Test func connectorNeedsACavityCount() {
        var h = Harness()
        #expect(throws: EditError.self) {
            try HarnessScript.addConnector(.init(mpn: "UNKNOWN-1"), part: PartRef(mpn: "UNKNOWN-1", manufacturer: ""), config: nil, to: &h)
        }
    }

    @Test func summaryIsCompactAndUseful() {
        let s = HarnessScript.summary(of: .sample)
        #expect(s.contains("C1"))
        #expect(s.contains("free ["))
        #expect(s.contains("Rule check:"))
        #expect(s.count < 4000)
    }
}
