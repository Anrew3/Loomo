import CoreGraphics
import Foundation
import Testing
@testable import CrimpCore
@testable import CrimpOutputs

@Suite struct BoxesMatesAndDrawingTests {
    @Test func imperialLengthsReadAsFeetAndInches() {
        let u = UnitSystem.imperial
        #expect(u.format(113 * 25.4) == "9 ft 5 in")
        #expect(u.format((31 * 12 + 7.75) * 25.4) == "31 ft 7.75 in")
        #expect(u.format(24 * 25.4) == "2 ft")
        #expect(u.format(6 * 25.4) == "6 in")
        #expect(u.format(1.75 * 25.4) == "1.75 in")
        #expect(u.format(20 * 25.4, decimals: 1) == "20.0 in")     // explicit decimals stay in inches
    }

    @Test func extraColoursAndTwoColourCodes() throws {
        #expect(try HarnessScript.wireColor("light blue") == WireColor("LB"))
        #expect(try HarnessScript.wireColor("VT GY") == WireColor("VT", stripe: "GY"))
        #expect(try HarnessScript.wireColor("LG/BK") == WireColor("LG", stripe: "BK"))
        #expect(WireTables.colorOrder.allSatisfy { WireTables.iecColors[$0] != nil })
    }

    @Test func fuseBoxFusesAreBOMLinesAndJoinNets() {
        var h = Harness()
        let box = h.addFuseBox(at: Point2D(0, 0), fuses: 2, rating: "10 A")
        let c = h.connector(box)!
        #expect(c.cavities.map(\.label) == ["1", "2", "3", "4"])
        #expect(c.boxItems.map(\.cavities) == [["1", "2"], ["3", "4"]])
        let pins = h.addLoosePins(at: Point2D(100, 0), count: 2)
        h.wires.append(Wire(id: "W1", size: .awg(18), color: WireColor("RD"), from: .pin(connector: pins, cavity: "1"), to: .pin(connector: box, cavity: "1")))
        h.wires.append(Wire(id: "W2", size: .awg(18), color: WireColor("RD"), from: .pin(connector: box, cavity: "2"), to: .pin(connector: pins, cavity: "2")))
        let a = HarnessAnalysis(h)
        let fuse = a.bom.first { $0.category == "Fuse" }
        #expect(fuse?.quantity == 2)
        #expect(fuse?.description == "10 A fuse")
        #expect(a.bom.contains { $0.category == "Fuse box" })
        #expect(!a.bom.contains { $0.references.contains(pins) && $0.category == "Connector" })   // loose pins have no housing
        // W1 and W2 are one net through fuse F1.
        #expect(a.nets.contains { Set($0.wires) == ["W1", "W2"] })
    }

    @Test func relaySocketHasISOCavities() {
        var h = Harness()
        let id = h.addRelay(at: Point2D(0, 0))
        #expect(h.connector(id)?.cavities.map(\.label) == ["30", "85", "86", "87", "87a"])
        #expect(h.connector(id)?.kind == .relay)
    }

    @Test func matedPairPassesSignalsThroughAndIsChecked() throws {
        var h = Harness()
        let (f, m) = h.addMatedPair(at: Point2D(200, 0), cavities: 2)
        #expect(h.connector(f)?.mate == m && h.connector(m)?.mate == f)
        #expect(h.connector(f)?.gender == .female && h.connector(m)?.gender == .male)
        let a1 = h.addLoosePins(at: Point2D(0, 0), count: 2), b1 = h.addLoosePins(at: Point2D(400, 0), count: 2)
        h.wires.append(Wire(id: "W1", size: .awg(20), color: WireColor("BK"), from: .pin(connector: a1, cavity: "1"), to: .pin(connector: f, cavity: "1")))
        h.wires.append(Wire(id: "W2", size: .awg(20), color: WireColor("BK"), from: .pin(connector: m, cavity: "1"), to: .pin(connector: b1, cavity: "1")))
        #expect(HarnessAnalysis(h).nets.contains { Set($0.wires) == ["W1", "W2"] })
        // Renaming keeps the link; deleting one half clears it.
        h.renameConnector(m, to: "C9M")
        #expect(h.connector(f)?.mate == "C9M")
        h.delete(["C9M"])
        #expect(h.connector(f)?.mate == nil)
        // The next connector doesn't reuse the pair's number.
        #expect(h.nextID(prefix: "C") != String(f.dropLast()))
    }

    @Test func matingTwoSameGenderConnectorsWarns() {
        var h = Harness()
        let a = h.addLoosePins(at: Point2D(0, 0), count: 1), b = h.addLoosePins(at: Point2D(50, 0), count: 1)
        h.setMate(a, b)
        #expect(HarnessAnalysis(h).issues.contains { $0.subject == a && $0.message.contains("both female") })
    }

    @Test func passThroughWiresMatchingCavities() throws {
        var h = Harness()
        let a = h.addLoosePins(at: Point2D(0, 0), count: 3), b = h.addLoosePins(at: Point2D(100, 0), count: 2)
        h.connectors[0].cavities[0].signal = "CANH"
        let made = try h.passThrough(from: a, to: b, size: .awg(22), color: WireColor("YE"))
        #expect(made.count == 2)
        #expect(h.wire(made[0])?.signal == "CANH")
        #expect(try h.passThrough(from: a, to: b, size: .awg(22), color: WireColor("YE")).isEmpty)   // already wired
    }

    @Test func itemNumbersAndTwistedWithInTables() {
        var h = Harness.sample
        h.twists.append(Twist(id: "TW1", wireIDs: ["W1", "W2"]))
        let a = HarnessAnalysis(h)
        #expect(a.bom.map(\.item) == Array(1...a.bom.count))
        #expect(a.itemNumbers["C1"] == a.bom.first { $0.references.contains("C1") && $0.category == "Connector" }?.item)
        let row = a.connectorTables.flatMap(\.rows).first { $0.wireID == "W1" }
        #expect(row?.twistedWith == "W2")
        #expect(row?.conductor.contains(".") == true || row?.conductor == h.wire("W1")?.color.description)
    }

    @Test func accessoriesGetTheirOwnBOMType() {
        var h = Harness.sample
        h.connectors[0].accessories.append(Accessory(kind: "lid lock", part: PartRef(mpn: "LL-1", manufacturer: "X"), quantity: 2))
        #expect(HarnessAnalysis(h).bom.contains { $0.category == "Lid lock" && $0.quantity == 2 })
    }

    @Test func newFieldsRoundTrip() throws {
        var h = Harness.sample
        _ = h.addFuseBox(at: Point2D(0, 0), fuses: 1, rating: "5 A")
        _ = h.addMatedPair(at: Point2D(10, 10), cavities: 1)
        h.connectors[0].imagePNG = Data([1, 2, 3])
        h.connectors[0].tableOffset = Point2D(5, 6)
        h.settings.showConnectionTables = true
        h.annotations.append(Annotation(id: "A9", kind: .frame, x: 0, y: 0, text: "Option"))
        h.annotations[h.annotations.count - 1].dashed = true
        #expect(try Harness.load(from: h.jsonData()) == h)
    }

    @Test func connectionTablesKeepClearOfBundles() {
        var h = Harness.sample
        h.settings.showConnectionTables = true
        let r = HarnessRenderer(harness: h, analysis: HarnessAnalysis(h))
        for s in h.splices {
            guard let f = r.tableFrame(for: s.id) else { continue }
            for seg in h.segments {
                guard let a = h.node(seg.nodeA)?.position, let b = h.node(seg.nodeB)?.position else { continue }
                #expect(!HarnessRenderer.crosses(f, CGPoint(x: a.x, y: a.y), CGPoint(x: b.x, y: b.y)))
            }
        }
    }

    @Test func formboardLayouts() {
        func pages(_ d: Data) -> Int { CGPDFDocument(CGDataProvider(data: d as CFData)!)?.numberOfPages ?? 0 }
        var single = FormboardOptions()
        single.layout = .singleSheet
        #expect(pages(Formboard.make(.sample, options: single)) == 1)
        var tiled = FormboardOptions()
        tiled.assemblyMap = false
        let plain = pages(Formboard.make(.sample, options: tiled))
        tiled.assemblyMap = true
        #expect(pages(Formboard.make(.sample, options: tiled)) == plain + 1)
        tiled.overlapMM = 20
        #expect(pages(Formboard.make(.sample, options: tiled)) >= plain + 1)
    }
}

@Suite struct PlaceComponentTests {
    func part(_ category: String?, _ description: String, positions: Int? = nil) -> PartRef {
        var p = PartRef(mpn: "X1", manufacturer: "M", description: description)
        p.category = category
        p.positionCount = positions
        return p
    }

    @Test func kindIsDetectedFromDistributorData() {
        #expect(ConnectorKind.detect(part("Fuse Holders", "ATO fuse holder 6 way")) == .fuseBox)
        #expect(ConnectorKind.detect(part("Automotive Relays", "Relay 12V 40A SPDT")) == .relay)
        #expect(ConnectorKind.detect(part("Terminals", "Ring Terminal M6 16-14 AWG")) == .ringTerminal)
        #expect(ConnectorKind.detect(part("Terminals", "FASTON 250 receptacle")) == .quickConnect)
        #expect(ConnectorKind.detect(part("Automotive Connectors", "PLUG DT 4 WAY")) == .housing)
        #expect(ConnectorKind.detect(nil) == .housing)
    }

    @Test func aRelayBecomesTheItemOfAnISOSocket() {
        var h = Harness()
        let relay = part("Automotive Relays", "Relay 12V 40A changeover", positions: 5)
        let id = h.placeComponent(part: relay, kind: .relay, at: Point2D(0, 0))
        let c = h.connector(id)!
        #expect(c.part == nil)
        #expect(c.cavities.map(\.label) == ["30", "85", "86", "87", "87a"])
        #expect(c.boxItems.first?.part == relay)
        // One BOM line for the relay, none for a socket that has no part.
        let a = HarnessAnalysis(h)
        #expect(a.bom.filter { $0.category == "Relay" }.count == 1)
    }

    @Test func aRelaySocketIsTheHousing() {
        var h = Harness()
        let socket = part("Relay Sockets", "Relay socket 5 way", positions: 5)
        let id = h.placeComponent(part: socket, kind: .relay, at: Point2D(0, 0))
        let c = h.connector(id)!
        #expect(c.part == socket && c.boxItems.first?.part == nil)
    }
}

@Suite struct AcceptedIssueLifecycleTests {
    @Test func acceptedDeviationsFollowARename() {
        var h = Harness.sample
        h.acceptedIssues = [AcceptedIssue(subject: "C1:2", message: "W2 (22 AWG) is below terminal X's 0.5 mm² minimum.", reason: "ok"),
                            AcceptedIssue(subject: "C1", message: "Cavity 3 carries W5 but has no terminal.", reason: "ok"),
                            AcceptedIssue(subject: "C10", message: "unrelated", reason: "ok")]
        h.renameConnector("C1", to: "C9")
        #expect(h.acceptedIssues.map(\.subject) == ["C9:2", "C9", "C10"])
        #expect(h.acceptedIssues[0].message.hasPrefix("W2 (22 AWG)"))
    }

    @Test func deletingAnItemDropsItsAcceptedDeviations() {
        var h = Harness.sample
        h.acceptedIssues = [AcceptedIssue(subject: "C1:2", message: "m", reason: "r"), AcceptedIssue(subject: "W1", message: "m", reason: "r"),
                            AcceptedIssue(subject: "C2", message: "m", reason: "r")]
        h.delete(["C1", "W1"])
        #expect(h.acceptedIssues.map(\.subject) == ["C2"])
    }
}

@Suite struct CavityRenameTests {
    @Test func renamingACavityMovesEverythingOnIt() {
        var h = Harness.sample
        let c = h.connectors[0].id
        let cav = h.connectors[0].cavities[0].label
        let wire = h.wires.first { $0.from == .pin(connector: c, cavity: cav) || $0.to == .pin(connector: c, cavity: cav) }?.id
        h.acceptedIssues = [AcceptedIssue(subject: "\(c):\(cav)", message: "m", reason: "r")]
        let renamed = h.renameCavity(c, cav, to: "A")
        #expect(renamed)
        #expect(h.connectors[0].cavities[0].label == "A")
        if let wire, let w = h.wire(wire) { #expect(w.from == .pin(connector: c, cavity: "A") || w.to == .pin(connector: c, cavity: "A")) }
        #expect(h.acceptedIssues[0].subject == "\(c):A")
        let clash = h.renameCavity(c, "A", to: h.connectors[0].cavities[1].label)    // label already taken
        #expect(!clash)
    }
}

@Suite struct PigtailTests {
    @Test func pigtailLeadIsSubtractedFromTheWire() {
        var h = Harness.sample
        let before = HarnessAnalysis(h).routes["W1"]?.lengthMM ?? 0
        let cid = h.wire("W1")!.from.connectorID!
        let i = h.connectors.firstIndex { $0.id == cid }!
        h.connectors[i].kind = .pigtail
        h.connectors[i].leadLengthMM = 150
        let after = HarnessAnalysis(h).routes["W1"]?.lengthMM ?? 0
        #expect(abs((before - after) - 150) < 0.001)
    }
}
