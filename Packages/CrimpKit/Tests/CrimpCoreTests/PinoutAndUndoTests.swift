import Foundation
import Testing
@testable import CrimpCore

@Suite struct PinoutEditingTests {
    @Test func placeIntoEmptyCavityMovesEnd() {
        var h = Harness.sample
        h.place(WireEnd("W1", .b), at: .pin(connector: "C2", cavity: "3"))
        #expect(h.wires[0].to == .pin(connector: "C2", cavity: "3"))
    }

    @Test func placeIntoOccupiedCavitySwaps() {
        var h = Harness.sample
        // W1·A is on C1:1, W2·A on C1:2.
        h.place(WireEnd("W1", .a), at: .pin(connector: "C1", cavity: "2"))
        #expect(h.wires[0].from == .pin(connector: "C1", cavity: "2"))
        #expect(h.wires[1].from == .pin(connector: "C1", cavity: "1"))
    }

    @Test func placeOnSpliceNeverSwaps() {
        var h = Harness.sample
        let before = h.wireEnds(at: .splice("SP1")).count
        h.place(WireEnd("W5", .a), at: .splice("SP1"))
        #expect(h.wireEnds(at: .splice("SP1")).count == before + 1)
    }

    @Test func unassignedEndIsWarningNotRouteError() {
        var h = Harness.sample
        h.unassign(WireEnd("W5", .b))
        let issues = HarnessAnalysis(h).issues.filter { $0.subject == "W5" }
        #expect(issues.contains { $0.severity == .warning && $0.message.contains("End B") })
        #expect(!issues.contains { $0.severity == .error })
        #expect(!WireVizExport.yaml(for: h).contains("W5"))
    }

    @Test func swapCavitiesMovesWiresAndContentsButKeepsLabels() {
        var h = Harness.sample
        h.swapCavities(connector: "C1", "1", "4")
        let x1 = h.connector("C1")!
        #expect(x1.cavities.map(\.label) == ["1", "2", "3", "4"])
        #expect(x1.cavities[3].signal == "5V")
        #expect(x1.cavities[0].plug?.mpn == "114017")
        #expect(h.wires[0].from == .pin(connector: "C1", cavity: "4"))
    }

    @Test func newWireTakesCavitySignal() {
        var h = Harness.sample
        let id = h.addWire(from: .pin(connector: "C1", cavity: "3"))
        let w = h.wires.first { $0.id == id }!
        #expect(w.signal == "SIG_A")
        #expect(w.to == .unassigned)
    }
}

@Suite struct UndoHistoryTests {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func burstOfUnnamedEditsIsOneStep() {
        var u = UndoHistory<Int>()
        u.record(previous: 0, name: nil, at: t0)
        u.record(previous: 1, name: nil, at: t0 + 0.3)
        u.record(previous: 2, name: nil, at: t0 + 0.6)
        #expect(u.undoStack.count == 1)
        #expect(u.undo(current: 3) == 0)
        #expect(u.redo(current: 0) == 3)
    }

    @Test func pauseStartsNewStep() {
        var u = UndoHistory<Int>()
        u.record(previous: 0, name: nil, at: t0)
        u.record(previous: 1, name: nil, at: t0 + 2)
        #expect(u.undoStack.count == 2)
    }

    @Test func namedActionsNeverMerge() {
        var u = UndoHistory<Int>()
        u.record(previous: 0, name: "Assign W1", at: t0)
        u.record(previous: 1, name: "Assign W2", at: t0 + 0.1)
        u.record(previous: 2, name: nil, at: t0 + 0.2)
        #expect(u.undoStack.map(\.name) == ["Assign W1", "Assign W2", "Edit"])
    }

    @Test func newEditClearsRedo() {
        var u = UndoHistory<Int>()
        u.record(previous: 0, name: "A", at: t0)
        _ = u.undo(current: 1)
        #expect(u.canRedo)
        u.record(previous: 0, name: "B", at: t0 + 5)
        #expect(!u.canRedo)
    }
}
