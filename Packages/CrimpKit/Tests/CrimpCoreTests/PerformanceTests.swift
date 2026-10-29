import CoreGraphics
import CrimpOutputs
import XCTest
@testable import CrimpCore

/// Timings on a large harness (60 connectors, 600 wires) for analysis, drawing and the PDF drawing set.
/// Xcode keeps a baseline per Mac; a run much slower than it fails. Use Product ▸ Profile with the
/// Points of Interest instrument to see the same intervals in the app.
final class PerformanceTests: XCTestCase {
    static let big: Harness = {
        var h = Harness(name: "Performance", revision: "A")
        var connectors: [EntityID] = []
        for i in 0..<60 {
            let spec = HarnessScript.ConnectorSpec(mpn: "PERF-12", manufacturer: "Test", cavities: 12)
            let part = PartRef(mpn: "PERF-12", manufacturer: "Test")
            connectors.append(try! HarnessScript.addConnector(spec, part: part, config: nil, to: &h,
                                                             at: Point2D(Double(i % 10) * 220, Double(i / 10) * 220)))
        }
        // A spine of splices so wires route through shared bundles.
        let hubs = (0..<6).map { h.addSplice(at: Point2D(Double($0) * 400 + 100, 1500)) }
        for (a, b) in zip(hubs, hubs.dropFirst()) { _ = try! h.addSegment(from: a, to: b, lengthMM: 300) }
        for (i, c) in connectors.enumerated() { _ = try! h.addSegment(from: c, to: hubs[i % hubs.count], lengthMM: 500) }
        for i in 0..<600 {
            let a = connectors[i % 60], b = connectors[(i * 7 + 13) % 60]
            let ca = String(i / 60 + 1), cb = String((i / 60 + 1) % 12 + 1)
            _ = try? HarnessScript.addWire(from: "\(a):\(ca)", to: "\(b):\(cb)", size: "20awg", color: "red",
                                           doubleCrimp: true, addBundle: false, in: &h)
        }
        return h
    }()

    func testAnalysisSpeed() {
        let h = Self.big
        XCTAssertGreaterThan(h.wires.count, 500)
        measure { _ = HarnessAnalysis(h) }
    }

    func testDrawingSpeed() {
        let h = Self.big
        let renderer = HarnessRenderer(harness: h, analysis: HarnessAnalysis(h), options: .init())
        let cg = CGContext(data: nil, width: 2400, height: 1800, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        measure { renderer.draw(in: cg) }
    }

    func testPDFSpeed() {
        let h = Self.big
        let analysis = HarnessAnalysis(h)
        measure { _ = PDFDrawingSet.make(h, analysis: analysis) }
    }
}
