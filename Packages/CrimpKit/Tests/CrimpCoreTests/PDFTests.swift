import CoreGraphics
import Foundation
import Testing
@testable import CrimpCore
@testable import CrimpOutputs

@Suite struct PDFTests {
    func pageCount(_ data: Data) -> Int {
        CGPDFDocument(CGDataProvider(data: data as CFData)!)?.numberOfPages ?? 0
    }

    @Test func drawingSetHasOnePageOrMorePerSection() {
        let data = PDFDrawingSet.make(.sample)
        #expect(pageCount(data) >= DrawingPage.allCases.count)
    }

    @Test func longTablesFlowOntoMorePages() {
        var h = Harness.sample
        for i in 0..<200 {
            h.wires.append(Wire(id: "WX\(i)", size: .awg(22), color: WireColor("WH"),
                                from: .pin(connector: "C1", cavity: "1"), to: .pin(connector: "C2", cavity: "1")))
        }
        #expect(pageCount(PDFDrawingSet.make(h, pages: [.cutList])) > 2)
    }

    @Test func formboardTilesAtFullScale() {
        // The sample is ~1.3 m long, so a 1:1 formboard on A3 needs several tiles.
        #expect(pageCount(PDFDrawingSet.formboard(.sample)) >= 3)
    }
}
