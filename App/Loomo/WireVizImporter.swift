import AppKit
import CrimpCore
import UniformTypeIdentifiers

/// File ▸ Import ▸ WireViz YAML…: reads a WireViz file into a new harness, saved next to it as a .loomo file.
enum WireVizImporter {
    @MainActor
    static func run() {
        let open = NSOpenPanel()
        open.message = "Choose a WireViz YAML file to turn into a Loomo harness."
        open.allowedContentTypes = [UTType(filenameExtension: "yml"), UTType(filenameExtension: "yaml")].compactMap { $0 }
        guard open.runModal() == .OK, let source = open.url else { return }
        do {
            let text = try String(contentsOf: source, encoding: .utf8)
            let (harness, report) = try WireVizImport.harness(fromYAML: text, name: source.deletingPathExtension().lastPathComponent)
            let save = NSSavePanel()
            save.allowedContentTypes = [.loomoHarness]
            save.directoryURL = source.deletingLastPathComponent()
            save.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".loomo"
            save.message = "Imported \(report.connectors) connectors, \(report.splices) splices and \(report.wires) wires. Save the new harness:"
            guard save.runModal() == .OK, let url = save.url else { return }
            try harness.jsonData().write(to: url, options: .atomic)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            if !report.skipped.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Some of the WireViz file wasn't imported"
                alert.informativeText = report.skipped.prefix(12).joined(separator: "\n")
                    + (report.skipped.count > 12 ? "\n…and \(report.skipped.count - 12) more" : "")
                alert.runModal()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Loomo couldn't import that WireViz file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
