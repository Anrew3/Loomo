import Foundation
import Testing
@testable import CrimpCore

@Suite struct ConnectWireTests {
    func twoConnectors() -> Harness {
        var h = Harness()
        h.placeConnector(part: nil, at: Point2D(0, 0))       // C1, node N1
        h.placeConnector(part: nil, at: Point2D(300, 400))   // C2, node N2
        return h
    }

    @Test func connectAddsWireAndBundleWhenMissing() {
        var h = twoConnectors()
        let a = Endpoint.pin(connector: "C1", cavity: "1"), b = Endpoint.pin(connector: "C2", cavity: "1")
        #expect(!h.hasRoute(a, b))
        let id = h.connect(a, b, size: .awg(18), color: WireColor("RD"), signal: "12V")
        #expect(h.segments.count == 1 && h.segments[0].lengthMM == 500)
        #expect(h.hasRoute(a, b))
        #expect(h.wire(id)?.signal == "12V")
        #expect(HarnessAnalysis(h).routes[id]?.pathLengthMM == 500)
        // A second wire reuses the bundle.
        h.connect(.pin(connector: "C1", cavity: "2"), .pin(connector: "C2", cavity: "2"))
        #expect(h.segments.count == 1)
    }

    @Test func noBundleWhenTurnedOff() {
        var h = twoConnectors()
        h.connect(.pin(connector: "C1", cavity: "1"), .pin(connector: "C2", cavity: "1"), addBundleIfMissing: false)
        #expect(h.segments.isEmpty)
    }

    @Test func firstFreeCavitySkipsUsedAndPlugged() {
        var h = Harness.sample
        // C1: 1–3 wired, 4 plugged → falls back to the plugged cavity.
        #expect(h.firstFreeCavity("C1") == "4")
        // C2: 1–2 wired → 3 free.
        #expect(h.firstFreeCavity("C2") == "3")
        h.connect(.pin(connector: "C1", cavity: "4"), .pin(connector: "C2", cavity: "3"))
        #expect(h.connector("C1")?.cavities[3].plug == nil)     // plug removed: a wire goes there now
        #expect(h.firstFreeCavity("C1") == nil)
    }

    @Test func addAndNextAdvances() {
        let h = twoConnectors()
        #expect(h.firstFreeCavity("C1", after: "1") == "2")
        #expect(h.firstFreeCavity("C1", after: "2") == "1")      // wraps around
    }

    @Test func signalComesFromCavity() {
        var h = Harness.sample
        h.connectors[0].cavities[3].signal = "CAN_H"
        let id = h.connect(.pin(connector: "C1", cavity: "4"), .pin(connector: "C3", cavity: "1"))
        #expect(h.wire(id)?.signal == "CAN_H")
    }

    @Test func libraryConfigurationSetsGenderFromContacts() {
        var h = Harness()
        let lib = PartLibrary.starter
        let p = lib.parts.first { $0.part.mpn == "DT04-4P" }!
        let s = lib.parts.first { $0.part.mpn == "DT06-2S" }!
        let a = h.placeConnector(part: p.part, at: Point2D(0, 0), configuration: p)
        let b = h.placeConnector(part: s.part, at: Point2D(9, 9), configuration: s)
        #expect(h.connector(a)?.gender == .male)
        #expect(h.connector(b)?.gender == .female)
    }
}
