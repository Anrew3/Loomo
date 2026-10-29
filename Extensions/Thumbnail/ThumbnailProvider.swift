import CoreGraphics
import CrimpCore
import CrimpOutputs
import Foundation
import QuickLookThumbnailing

/// Finder thumbnails for .loomo (the harness drawing, cropped to its content) and
/// .loomosys files (the system diagram page).
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let data = try Data(contentsOf: request.fileURL)
            let library = DocumentPreview.useAppData()
            // Drawings are landscape: fit a 4:3 sheet inside the requested square.
            let max = request.maximumSize
            let size = CGSize(width: max.width, height: (max.width * 0.75).rounded())
            // The drawing context is in pixels (size × scale, e.g. 2× on Retina); draw in points.
            let scale = request.scale
            if request.fileURL.pathExtension.lowercased() == "loomosys" {
                let pdf = try DocumentPreview.pdf(for: data, isSystem: true, library: library)
                handler(QLThumbnailReply(contextSize: size) { cg in
                    cg.scaleBy(x: scale, y: scale)
                    DocumentPreview.drawFirstPage(of: pdf, in: cg, size: size)
                    return true
                }, nil)
            } else {
                let harness = try Harness.load(from: data)
                handler(QLThumbnailReply(contextSize: size) { cg in
                    cg.scaleBy(x: scale, y: scale)
                    DocumentPreview.drawThumbnail(harness, library: library, in: cg, size: size)
                    return true
                }, nil)
            }
        } catch {
            handler(nil, error)
        }
    }
}
