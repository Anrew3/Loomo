import CoreGraphics
import CrimpCore
import Foundation

/// Drawing for Finder: Quick Look thumbnails and previews of .loomo and .loomosys files.
/// Shared by the app's Quick Look extensions so it can be tested here.
public enum DocumentPreview {
    /// The user's real home folder. Inside a sandboxed extension `NSHomeDirectory()` is the
    /// extension's container, which has none of the app's data.
    public static var userHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Points drawings at the app's part photos and parts library (custom photos) in the user's
    /// Library folder, so previews show the same photos as the app. Returns the library, if any.
    @discardableResult
    public static func useAppData(home: URL = userHome) -> PartLibrary? {
        // App Store build: the app shares this data with its extensions through an App Group.
        if SharedStorage.appGroup != nil {
            PartImageCache.shared = PartImageCache()
            let file = PartLibrary.defaultURL
            return FileManager.default.fileExists(atPath: file.path) ? PartLibrary.load(from: file) : nil
        }
        let library = home.appendingPathComponent("Library", isDirectory: true)
        PartImageCache.shared = PartImageCache(directory: library.appendingPathComponent("Caches/Loomo/PartImages", isDirectory: true))
        let libraryFile = library.appendingPathComponent("Application Support/Loomo/Library.json")
        guard FileManager.default.fileExists(atPath: libraryFile.path) else { return nil }
        return PartLibrary.load(from: libraryFile)
    }

    /// Draws a harness, cropped to its content, on white paper filling `size`.
    /// `cg` is a normal (y-up) Core Graphics context, as Quick Look supplies.
    public static func drawThumbnail(_ h: Harness, library: PartLibrary?, in cg: CGContext, size: CGSize) {
        var options = HarnessRenderer.Options()
        if let library { options.photoURL = { library.photoURL(for: $0) } }
        let renderer = HarnessRenderer(harness: h, analysis: HarnessAnalysis(h), options: options)
        let b = renderer.bounds
        cg.setFillColor(CGColor(gray: 1, alpha: 1))
        cg.fill(CGRect(origin: .zero, size: size))
        guard b.width > 0, b.height > 0 else { return }
        let margin = min(size.width, size.height) * 0.06
        let scale = min((size.width - 2 * margin) / b.width, (size.height - 2 * margin) / b.height)
        cg.saveGState()
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)   // the renderer draws y-down, like the canvas and PDF pages
        cg.translateBy(x: (size.width - b.width * scale) / 2, y: (size.height - b.height * scale) / 2)
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -b.minX, y: -b.minY)
        renderer.draw(in: cg)
        cg.restoreGState()
    }

    /// Pages shown when previewing a harness: the drawing, then the tables people check most.
    public static let previewPages: [DrawingPage] = [.harness, .connectorFaces, .wiringTable, .bom]

    /// A PDF preview of a harness, or of a system project's own pages (diagram, netlist, BOM…).
    /// The file type decides: harness files are read leniently, so a system file would also parse as one.
    public static func pdf(for data: Data, isSystem: Bool, library: PartLibrary?) throws -> Data {
        if isSystem {
            return SystemPDF.make(try SystemProject.load(from: data), includeHarnessDrawings: false)
        }
        return PDFDrawingSet.make(try Harness.load(from: data), pages: previewPages, library: library)
    }

    /// The first page of a PDF drawn to fill `size` (used for system-project thumbnails).
    public static func drawFirstPage(of pdf: Data, in cg: CGContext, size: CGSize) {
        cg.setFillColor(CGColor(gray: 1, alpha: 1))
        cg.fill(CGRect(origin: .zero, size: size))
        guard let provider = CGDataProvider(data: pdf as CFData), let doc = CGPDFDocument(provider),
              let page = doc.page(at: 1) else { return }
        let box = page.getBoxRect(.mediaBox)
        let scale = min(size.width / box.width, size.height / box.height)
        cg.saveGState()
        cg.translateBy(x: (size.width - box.width * scale) / 2, y: (size.height - box.height * scale) / 2)
        cg.scaleBy(x: scale, y: scale)
        cg.drawPDFPage(page)
        cg.restoreGState()
    }
}
