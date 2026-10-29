import CoreGraphics
import Foundation
import Testing
@testable import CrimpCore
@testable import CrimpOutputs

@Suite struct ConnectorFaceTests {
    let h = Harness.sample

    @Test func presetsPlaceEveryCavityInsideTheHousing() {
        let labels = (1...8).map(String.init)
        for preset in FaceLayout.Preset.allCases {
            let l = FaceLayout.preset(preset, labels: labels)
            #expect(l.cavities.map(\.label) == labels)
            for c in l.cavities {
                #expect(abs(c.x) + c.diameter / 2 <= l.width / 2 + 0.001, "\(preset)")
                #expect(abs(c.y) + c.diameter / 2 <= l.height / 2 + 0.001, "\(preset)")
            }
            #expect(Set(l.cavities.map { "\($0.x),\($0.y)" }).count == 8, "\(preset) overlaps")
        }
    }

    @Test func automaticLayoutFollowsCavityCount() {
        #expect(FaceLayout.automatic(for: h.connector("C1")!).source == "Preset: Two rows")    // 4-way
        #expect(FaceLayout.automatic(for: h.connector("C2")!).source == "Preset: Single row")  // 3-way
    }

    @Test func wireSideMirrors() {
        let l = FaceLayout.preset(.singleRow, labels: ["1", "2", "3"])
        #expect(l.cavity("1")!.x < l.cavity("3")!.x)
        #expect(l.mirrored().cavity("1")!.x > l.mirrored().cavity("3")!.x)
    }

    @Test func cavitiesAreColouredByWire() {
        let x1 = h.connector("C1")!
        let d = h.faceDrawing(for: x1, layout: h.faceLayout(for: x1))
        let fills = d.primitives.compactMap { p -> String? in
            if case let .circle(_, _, r, fill?, _, _) = p, r > 6 { return fill }
            return nil
        }
        #expect(fills.contains(WireTables.iecColors["RD"]!))      // W1 5V in cavity 1
        #expect(fills.contains(WireTables.iecColors["GN"]!))      // W5 GN/WH in cavity 3
        #expect(d.primitives.contains { if case .stripe = $0 { return true } else { return false } })
        #expect(d.primitives.contains { if case .hatch = $0 { return true } else { return false } })   // cavity 4 plugged
        #expect(d.cavityHits.count == 4)
        let (x, y, _) = d.cavityHits["2"]!
        #expect(d.cavity(at: x, y) == "2")
    }

    @Test func libraryLayoutIsSharedAndOwnOverrides() {
        var lib = PartLibrary.starter
        let i = lib.parts.firstIndex { $0.part.mpn == "DT06-4S" }!
        lib.parts[i].faceLayout = FaceLayout.preset(.circular, labels: ["A", "B", "C", "D"])
        var x1 = h.connector("C1")!
        // Same count, different labels: geometry reused, labels taken from the connector.
        #expect(h.faceLayout(for: x1, library: lib).shape == .circle)
        #expect(h.faceLayout(for: x1, library: lib).cavities.map(\.label) == ["1", "2", "3", "4"])
        x1.faceLayout = FaceLayout.preset(.singleRow, labels: ["1", "2", "3", "4"])
        #expect(h.faceLayout(for: x1, library: lib).shape == .rounded)
    }

    @Test func svgIsWellFormed() throws {
        let x1 = h.connector("C1")!
        var o = FaceDrawingOptions()
        o.title = "C1 <Main> & co"
        let svg = h.faceDrawing(for: x1, layout: h.faceLayout(for: x1), options: o).svg()
        #expect(svg.hasPrefix("<svg"))
        #expect(svg.contains("&lt;Main&gt; &amp; co"))
        let doc = try XMLDocument(xmlString: svg)
        #expect(doc.rootElement()?.name == "svg")
    }

    @Test func pdfHasConnectorFacesPage() {
        let data = PDFDrawingSet.make(h, pages: [.connectorFaces])
        #expect(CGPDFDocument(CGDataProvider(data: data as CFData)!)?.numberOfPages == 1)   // 3 housings fit one sheet
    }
}

@Suite struct DistributorFaceTests {
    @Test func rowsAndPitchDriveAutomaticFace() {
        var h = Harness()
        var part = PartRef(mpn: "502351-0801", manufacturer: "Molex")
        part.positionCount = 8
        part.rowCount = 1
        part.pitchMM = 2
        part.contactGender = "Female"
        let id = h.placeConnector(part: part, at: Point2D(0, 0))
        let c = h.connector(id)!
        #expect(c.cavities.count == 8)
        let l = h.faceLayout(for: c)
        #expect(Set(l.cavities.map(\.y)).count == 1)                       // one row
        #expect(abs(l.cavity("2")!.x - l.cavity("1")!.x - 2) < 1e-9)       // 2 mm pitch
        #expect(l.source.contains("1 row"))
    }

    @Test func partCountBeatsStaleLibraryCount() {
        var h = Harness()
        var part = PartRef(mpn: "502351-0801", manufacturer: "Molex")
        part.positionCount = 8
        let stale = LibraryPart(part: PartRef(mpn: "502351-0801", manufacturer: "Molex"), category: "connector", cavityCount: 2)
        let id = h.placeConnector(part: part, at: Point2D(0, 0), configuration: stale)
        #expect(h.connector(id)?.cavities.count == 8)
    }

    @Test func libraryConfigurationKeepsDistributorDetails() {
        var h = Harness()
        var part = PartRef(mpn: "502351-0801", manufacturer: "Molex")
        part.positionCount = 8
        part.rowCount = 1
        part.pitchMM = 2
        var libPart = PartRef(mpn: "5023510801", manufacturer: "Molex")
        libPart.internalPN = "CL-1001"
        let config = LibraryPart(part: libPart, category: "connector", cavityCount: 2)
        let id = h.placeConnector(part: part, at: Point2D(0, 0), configuration: config)
        let c = h.connector(id)!
        #expect(c.part?.rowCount == 1 && c.part?.pitchMM == 2)
        #expect(c.part?.internalPN == "CL-1001")
        #expect(Set(h.faceLayout(for: c).cavities.map(\.y)).count == 1)
    }
}
