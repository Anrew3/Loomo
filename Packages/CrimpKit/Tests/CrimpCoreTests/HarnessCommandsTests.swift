@testable import CrimpCore
import Foundation
import Testing

@Suite struct HarnessCommandsTests {
    typealias O = HarnessCommands.Options

    @Test func catalogNamesAreUniqueAndEveryCommandRuns() throws {
        let names = HarnessCommands.catalog.map(\.name)
        #expect(Set(names).count == names.count)
        // Every catalogued command is handled (an unhandled one would throw "Unknown command").
        for c in HarnessCommands.catalog {
            var h = Harness.sample
            do { _ = try HarnessCommands.run(c.name, O(), on: &h) } catch let e as EditError {
                #expect(!(e.errorDescription ?? "").hasPrefix("Unknown command"), "\(c.name) isn't handled")
            }
        }
    }

    @Test func readCommandsDontChangeTheHarness() throws {
        for c in HarnessCommands.catalog where !c.edits {
            var h = Harness.sample
            _ = try HarnessCommands.run(c.name, O(), on: &h)
            #expect(h == Harness.sample, "\(c.name) changed the harness")
        }
    }

    @Test func aFailedEditLeavesTheHarnessUntouched() {
        var h = Harness.sample
        // pass-through adds wires one by one; a bad colour must not leave half of them behind.
        #expect(throws: (any Error).self) {
            try HarnessCommands.run("pass-through", O(values: ["from": "C1", "to": "C2", "color": "plaid"]), on: &h)
        }
        #expect(h == Harness.sample)
    }

    @Test func addWireReportsWhatItMade() throws {
        var h = Harness.sample
        let c = h.connectors[0].id
        let free = h.connectors[0].cavities.first { !h.isOccupied(.pin(connector: c, cavity: $0.label)) }!.label
        let s = h.splices[0].id
        let out = try HarnessCommands.run("add-wire", O(values: ["from": "\(c):\(free)", "to": s, "size": "18awg", "color": "red/white", "id": "W77"]), on: &h)
        #expect(out["created"] as? String == "W77")
        #expect(h.wire("W77")?.color == WireColor("RD", stripe: "WH"))
    }

    @Test func renameConnectorAndCavity() throws {
        var h = Harness.sample
        let c = h.connectors[0].id
        let cav = h.connectors[0].cavities[0].label
        _ = try HarnessCommands.run("rename-connector", O(values: ["connector": c, "to": "C99"]), on: &h)
        #expect(h.connector("C99") != nil && h.connector(c) == nil)
        _ = try HarnessCommands.run("rename-cavity", O(values: ["connector": "C99", "cavity": cav, "to": "A"]), on: &h)
        #expect(h.connector("C99")?.cavities[0].label == "A")
        #expect(throws: EditError.self) { try HarnessCommands.run("rename-connector", O(values: ["connector": "NOPE", "to": "C1"]), on: &h) }
    }

    @Test func moveRepositionsTheNode() throws {
        var h = Harness.sample
        let c = h.connectors[0]
        _ = try HarnessCommands.run("move", O(values: ["id": c.id, "x": "12.5", "y": "40"]), on: &h)
        #expect(h.node(c.nodeID!)?.position == Point2D(12.5, 40))
    }

    @Test func removeTakesAListOrPositionalIDs() throws {
        var h = Harness.sample
        let w = h.wires.prefix(2).map(\.id)
        _ = try HarnessCommands.run("remove", O(values: ["ids": w.joined(separator: ", ")]), on: &h)
        #expect(w.allSatisfy { h.wire($0) == nil })
    }

    @Test func badValuesAreErrorsNotCrashes() {
        var h = Harness.sample
        #expect(throws: EditError.self) { try HarnessCommands.run("add-fuse-box", O(values: ["fuses": "six"]), on: &h) }
        #expect(throws: EditError.self) { try HarnessCommands.run("set", O(values: ["units": "furlongs"]), on: &h) }
        #expect(throws: EditError.self) { try HarnessCommands.run("move", O(values: ["id": "C1"]), on: &h) }
    }
}
