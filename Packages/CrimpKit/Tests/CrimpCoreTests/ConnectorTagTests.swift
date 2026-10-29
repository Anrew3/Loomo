import CoreGraphics
import CrimpOutputs
import Foundation
import Testing
@testable import CrimpCore

@Suite struct ConnectorTagTests {
    @Test func photoAndTextMoveTogether() {
        var c = Connector(id: "C1", nodeID: "N1", cavityCount: 2)
        let dot = CGPoint(x: 100, y: 200)
        let home = HarnessRenderer.tag(for: c, at: dot, hasPhoto: true)
        #expect(!home.moved)
        #expect(home.photo == HarnessRenderer.photoBox(at: dot))

        c.tagOffset = Point2D(80, -40)
        let moved = HarnessRenderer.tag(for: c, at: dot, hasPhoto: true)
        #expect(moved.moved)
        #expect(moved.photo == home.photo.offsetBy(dx: 80, dy: -40))
        #expect(moved.titleY == home.titleY - 40)
        #expect(moved.frame == home.frame.offsetBy(dx: 80, dy: -40))
    }

    @Test func tagPositionAndLockAreSaved() throws {
        var h = Harness.sample
        h.connectors[0].tagOffset = Point2D(-60, 30)
        h.connectors[0].tagUnlocked = true
        let back = try Harness.load(from: h.jsonData())
        #expect(back.connectors[0].tagOffset == Point2D(-60, 30))
        #expect(back.connectors[0].tagUnlocked == true)
    }

    @Test func movedTagWidensTheDrawingBounds() {
        var h = Harness.sample
        let before = HarnessRenderer(harness: h, analysis: HarnessAnalysis(h)).bounds
        h.connectors[0].tagOffset = Point2D(0, -600)
        let after = HarnessRenderer(harness: h, analysis: HarnessAnalysis(h)).bounds
        #expect(after.minY < before.minY - 400)
    }
}
