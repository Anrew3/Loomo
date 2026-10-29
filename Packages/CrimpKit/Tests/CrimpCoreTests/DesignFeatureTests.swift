import Foundation
import Testing
@testable import CrimpCore

@Suite struct LengthTests {
    @Test func insertionDepthAndBackshellAddToBothEnds() {
        var h = Harness.sample
        h.connectors[0].insertionDepthMM = 12
        h.connectors[0].backshellEntryMM = 30
        h.wires[0].extraLengthMM = 50
        // W1: 1050 path + (20 + 12 + 30) at C1 + 20 at C2 + 50 extra.
        #expect(HarnessAnalysis(h).routes["W1"]?.lengthMM == 1182)
    }

    @Test func twistedWiresAreLonger() {
        var h = Harness.sample
        // W3 and W4 both start at SP1; twist W2/W3 doesn't matter for take-up, only per-wire.
        h.twist(["W1", "W5"], layLengthMM: 20)
        let r = HarnessAnalysis(h).routes["W1"]!
        #expect(r.twistTakeUpMM > 0)
        #expect(r.lengthMM! > 1090)
        // They route differently, which the rule checker reports.
        #expect(HarnessAnalysis(h).issues.contains { $0.subject == h.twists[0].id })
    }
}

@Suite struct CableTests {
    @Test func cableCountsOnceInBundleAndReplacesCoresInBOM() {
        var h = Harness.sample
        let before = HarnessAnalysis(h).bundleDiameterMM["S3"]!
        let id = h.makeCable(from: ["W1", "W3"], shielded: true)
        h.cables[0].part = PartRef(mpn: "SAMPLE-2C-SH", manufacturer: "Sample")
        h.cables[0].jacketODMM = 4
        let a = HarnessAnalysis(h)
        #expect(a.bundleDiameterMM["S3"] == 4)          // only the cable runs on S3
        #expect(before < 4)
        #expect(a.bom.contains { $0.category == "Cable" && $0.mpn == "SAMPLE-2C-SH" })
        #expect(!a.bom.contains { $0.category == "Wire" && $0.references.contains("W1") })
        #expect(a.cutList.contains { $0.wireID == id && $0.kind == "Cable jacket" })
        #expect(a.issues.contains { $0.subject == id && $0.message.contains("drain") })
    }
}

@Suite struct RuleTests {
    @Test func terminalWireRangeIsChecked() {
        var h = Harness.sample
        h.wires[0].size = .awg(12)   // 3.31 mm² into a 0.5–1.5 mm² contact
        #expect(HarnessAnalysis(h).issues.contains { $0.severity == .error && $0.subject == "C1:1" && $0.message.contains("maximum") })
    }

    @Test func genericPartsAreFlagged() {
        #expect(HarnessAnalysis(.sample).issues.contains { $0.subject == "C4:1" && $0.message.contains("Generic") })
    }
}

@Suite struct OutputTests {
    @Test func netlistJoinsWiresThroughSplices() {
        let nets = HarnessAnalysis(.sample).nets
        let gnd = nets.first { $0.name == "GND" }!
        #expect(gnd.members == ["C1:2", "C2:2", "C3:2", "C4:1"])
        #expect(gnd.wires == ["W2", "W3", "W4", "W6"])
    }

    @Test func connectorTableListsEveryCavity() {
        let t = HarnessAnalysis(.sample).connectorTables.first { $0.connectorID == "C1" }!
        #expect(t.rows.map(\.cavity) == ["1", "2", "3", "4"])
        #expect(t.rows[3].destination.contains("114017"))
    }

    @Test func labelTextSyncsWithConnector() {
        var h = Harness.sample
        h.connectors[0].name = "ECU"
        #expect(HarnessAnalysis(h).labelList.first { $0.id == "L1" }?.text == "C1 ECU")
        #expect(HarnessAnalysis(h).labelList.contains { $0.id == "W6·A" })
    }

    @Test func toolsListComesFromTerminals() {
        let tool = HarnessAnalysis(.sample).toolList.first { $0.name == "HDT-48-00" }!
        #expect(tool.usedFor == ["0462-201-16141 ×3"])
    }

    @Test func xlsxIsAValidZip() throws {
        let h = Harness.sample
        let data = HarnessAnalysis(h).workbook(for: h).data()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("t.xlsx")
        try data.write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-tq", file.path]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(ZipStore.crc32(Data("123456789".utf8)) == 0xCBF43926)
    }
}

@Suite struct OperationTests {
    @Test func replacePartEverywhere() {
        var h = Harness.sample
        let old = h.connectors[0].cavities[0].terminal!
        let new = PartRef(mpn: "0462-209-16141", manufacturer: old.manufacturer)
        #expect(h.replacePart(old, with: new) == 3)
        #expect(h.usages(of: new).sorted() == ["C1:1", "C1:2", "C1:3"])
    }

    @Test func layoutToScaleMatchesSegmentLengths() {
        var h = Harness.sample
        h.layoutToScale(pointsPerMM: 0.5)
        for s in h.segments {
            let a = h.node(s.nodeA)!.position, b = h.node(s.nodeB)!.position
            #expect(abs(hypot(a.x - b.x, a.y - b.y) - s.lengthMM * 0.5) < 0.01)
        }
    }

    @Test func copyPasteSectionRenamesEverything() {
        var h = Harness.sample
        let clip = h.copySection(nodeIDs: ["N3", "N4", "N5"])
        #expect(clip.connectors.map(\.id).sorted() == ["C2", "C3"])
        #expect(clip.segments.map(\.id).sorted() == ["S3", "S4"])
        #expect(clip.wires.isEmpty)   // no wire has both ends inside
        let newNodes = h.paste(clip)
        #expect(newNodes.count == 3)
        #expect(h.connectors.count == 6)
        #expect(Set(h.connectors.map(\.id)).count == 6)
        #expect(h.coverings.count == 3)  // tape on S3/S4 came along
    }

    @Test func remapMovesWireEnds() {
        var h = Harness.sample
        h.connectors.append(Connector(id: "C9", cavityCount: 3))
        let missing = h.remapConnections(from: "C2", to: "C9", cavityMap: ["2": "3"])
        #expect(missing.isEmpty)
        #expect(h.wires.first { $0.id == "W3" }?.to == .pin(connector: "C9", cavity: "3"))
    }

    @Test func libraryConfigurationFillsConnector() {
        let lib = PartLibrary.starter
        let cfg = lib.parts.first { $0.part.mpn == "DT06-2S" }!
        var c = Connector(id: "C7", cavityCount: 6)
        c.apply(cfg, usedCavities: ["1"])
        #expect(c.cavities.count == 2)
        #expect(c.cavities.allSatisfy { $0.terminal?.mpn == "0462-201-16141" })
        #expect(c.cavities[1].plug?.mpn == "114017" && c.cavities[0].plug == nil)
        #expect(c.accessories.map(\.part.mpn) == ["W2S"])
    }
}

@Suite struct ImportTests {
    @Test func csvHandlesQuotesAndTabs() {
        #expect(CSV.parse("a,\"b,c\",\"d\"\"e\"\n1,2,3\n") == [["a", "b,c", "d\"e"], ["1", "2", "3"]])
        #expect(CSV.parse("x\ty\n1\t2") == [["x", "y"], ["1", "2"]])
    }

    @Test func wireListCreatesConnectorsAndWires() {
        var h = Harness()
        let r = h.importWireList(csv: """
        Wire,Signal,From,To,Gauge,Color,Length
        W1,CAN_H,ECU:12,OBD:6,22,YE/GN,1500
        W2,CAN_L,ECU:13,OBD:14,22 AWG,GN,1500
        W3,GND,ECU:1,SP1,0.75 mm2,BK,
        """)
        #expect(r.wiresAdded == 3)
        #expect(r.connectorsCreated.sorted() == ["ECU", "OBD"])
        #expect(h.connector("ECU")!.cavities.count == 13)
        #expect(h.wires[0].color == WireColor("YE", stripe: "GN"))
        #expect(h.wires[2].size.crossSectionMM2 == 0.75)
        #expect(h.wires[2].to == .splice("SP1"))
        #expect(h.wires[0].lengthOverrideMM == 1500)
    }

    @Test func pinListSetsSignals() {
        var h = Harness.sample
        let n = h.importPinList(csv: "Pin,Signal\n1,VREF\n2,SENSOR_GND\n", into: "C2")
        #expect(n == 2)
        #expect(h.connector("C2")!.cavities[0].signal == "VREF")
    }
}
