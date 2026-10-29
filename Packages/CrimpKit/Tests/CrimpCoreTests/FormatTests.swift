import Foundation
import Testing
@testable import CrimpCore

@Suite struct FormatTests {
    @Test func wireEndsAreTidy() throws {
        let json = String(decoding: try Harness.sample.jsonData(), as: UTF8.self)
        #expect(json.contains(#""splice" : "SP1""#))
        #expect(json.contains(#""pin" : {"#))
        #expect(!json.contains("_0"))
    }

    @Test func roundTripsExactly() throws {
        let h = Harness.sample
        #expect(try Harness.load(from: h.jsonData()) == h)
    }

    @Test func minimalHandWrittenFileLoadsWithDefaults() throws {
        let json = #"""
        {
          "name": "Bench lead",
          "nodes": [{"id": "N1", "kind": "connector", "position": {"x": 0, "y": 0}},
                    {"id": "N2", "kind": "splice", "position": {"x": 100, "y": 0}}],
          "segments": [{"id": "S1", "nodeA": "N1", "nodeB": "N2", "lengthMM": 150}],
          "connectors": [{"id": "C1", "nodeID": "N1",
                          "part": {"mpn": "DT06-2S", "manufacturer": "TE"},
                          "cavities": [{"label": "1"}, {"label": "2"}]}],
          "splices": [{"id": "SP1", "nodeID": "N2"}],
          "wires": [{"id": "W1", "size": {"awg": 18}, "color": {"base": "RD"},
                     "from": {"pin": {"connector": "C1", "cavity": "1"}}, "to": {"splice": "SP1"}}]
        }
        """#
        let h = try Harness.load(from: Data(json.utf8))
        #expect(h.revision == "A")
        #expect(h.settings.terminationAllowanceMM == 20)
        #expect(h.connectors[0].gender == .female)
        #expect(h.wires[0].insulation == "TXL")
        #expect(h.wires[0].outerDiameterMM > 0)
        #expect(h.wires[0].size.crossSectionMM2 > 0.8)
        let a = HarnessAnalysis(h)
        // 150 mm of bundle plus 20 mm allowance at each end.
        #expect(a.routes["W1"]?.lengthMM == 190)
    }

    @Test func badWireEndExplainsItself() {
        let json = #"{"wires": [{"id": "W1", "size": {"awg": 18}, "from": {"pins": {}}, "to": {"splice": "SP1"}}]}"#
        #expect(throws: DecodingError.self) { try Harness.load(from: Data(json.utf8)) }
    }

    @Test func splicesCanShareAJunction() throws {
        var h = Harness()
        let a = h.addSplice(at: Point2D(0, 0))
        let n = try #require(h.splice(a)?.nodeID)
        let b = h.addSplice(at: Point2D(0, 0), onNode: n)
        #expect(h.splice(b)?.nodeID == n)
        #expect(h.node(n)?.label == "SP1 · SP2")
    }

    @Test func systemConnectorRefsAreTidy() throws {
        let data = try JSONEncoder().encode(ConnectorRef.harness("H1", connector: "C2"))
        #expect(String(decoding: data, as: UTF8.self).contains(#""harness":"H1""#))
        #expect(try JSONDecoder().decode(ConnectorRef.self, from: data) == .harness("H1", connector: "C2"))
    }
}

@Suite struct AcceptedIssueTests {
    @Test func acceptedCheckBecomesInfoUntilTheDesignChanges() throws {
        var h = Harness.sample
        let open = try #require(HarnessAnalysis(h).issues.first { $0.severity == .warning })
        h.acceptedIssues.append(AcceptedIssue(subject: open.subject, message: open.message, reason: "Reviewed"))
        let accepted = try #require(HarnessAnalysis(h).issues.first { $0.subject == open.subject && $0.message == open.message })
        #expect(accepted.severity == .info)
        #expect(accepted.acceptedReason == "Reviewed")
        // A different message (the design changed) is not covered.
        h.acceptedIssues[0].message += " (old)"
        #expect(HarnessAnalysis(h).issues.contains { $0.message == open.message && $0.severity == open.severity })
        #expect(try Harness.load(from: h.jsonData()).acceptedIssues == h.acceptedIssues)
    }
}
