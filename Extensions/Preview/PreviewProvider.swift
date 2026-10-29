import CrimpCore
import CrimpOutputs
import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Spacebar preview in Finder: the harness drawing, connector faces, wiring table and BOM as a PDF
/// (for a system project, its diagram, netlist, BOM and mates).
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL)
        let library = DocumentPreview.useAppData()
        let isSystem = request.fileURL.pathExtension.lowercased() == "loomosys"
        let pdf = try DocumentPreview.pdf(for: data, isSystem: isSystem, library: library)
        // A3 landscape, the default sheet; Quick Look scales to the window.
        return QLPreviewReply(dataOfContentType: .pdf, contentSize: CGSize(width: 1191, height: 842)) { _ in pdf }
    }
}
