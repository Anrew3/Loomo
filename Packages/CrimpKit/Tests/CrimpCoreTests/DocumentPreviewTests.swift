import CoreGraphics
import CrimpOutputs
import Foundation
import PDFKit
import Testing
@testable import CrimpCore

@Suite struct DocumentPreviewTests {
    /// Renders into a small bitmap and counts pixels that aren't white paper.
    private func inkedPixels(_ draw: (CGContext, CGSize) -> Void) throws -> Int {
        let size = CGSize(width: 256, height: 192)
        let cg = try #require(CGContext(data: nil, width: 256, height: 192, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(cg, size)
        let bytes = try #require(cg.data).assumingMemoryBound(to: UInt8.self)
        var n = 0
        for i in stride(from: 0, to: cg.bytesPerRow * 192, by: 4) where bytes[i] < 200 || bytes[i + 1] < 200 || bytes[i + 2] < 200 { n += 1 }
        return n
    }

    @Test func thumbnailShowsTheHarness() throws {
        let empty = try inkedPixels { DocumentPreview.drawThumbnail(Harness(), library: nil, in: $0, size: $1) }
        let sample = try inkedPixels { DocumentPreview.drawThumbnail(.sample, library: nil, in: $0, size: $1) }
        #expect(empty == 0)
        #expect(sample > 300)   // bundles, dots and labels drawn
    }

    @Test func previewIsAMultiPagePDF() throws {
        let pdf = try DocumentPreview.pdf(for: Harness.sample.jsonData(), isSystem: false, library: nil)
        let doc = try #require(PDFDocument(data: pdf))
        #expect(doc.pageCount >= DocumentPreview.previewPages.count)
    }

    @Test func systemPreviewUsesTheSystemPages() throws {
        let pdf = try DocumentPreview.pdf(for: SystemProject.sample.encoded(), isSystem: true, library: nil)
        #expect(try #require(PDFDocument(data: pdf)).pageCount >= 1)
        let ink = try inkedPixels { DocumentPreview.drawFirstPage(of: pdf, in: $0, size: $1) }
        #expect(ink > 100)
    }
}
