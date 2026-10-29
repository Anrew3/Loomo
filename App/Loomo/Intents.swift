import AppIntents
import CrimpCore
import CrimpOutputs
import Foundation
import UniformTypeIdentifiers

// Shortcuts, Spotlight and Siri actions. They work on .loomo files directly, without opening a window,
// so they also fit automations ("when a harness is added to this folder, check it and export the PDF").


private func loadHarness(_ file: IntentFile) throws -> Harness {
    do {
        return try Harness.load(from: file.data)
    } catch {
        throw IntentError.unreadable(file.filename)
    }
}

/// The output file name: the input's name with a new extension.
private func outputName(_ file: IntentFile, _ ext: String) -> String {
    ((file.filename as NSString).deletingPathExtension) + "." + ext
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case unreadable(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case let .unreadable(name): "\(name) isn't a Loomo harness file."
        }
    }
}

struct CheckHarnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Harness"
    static let description = IntentDescription("Runs the Loomo rule checker on a harness and returns its errors and warnings.",
                                               categoryName: "Harness")

    @Parameter(title: "Harness", supportedContentTypes: [UTType(exportedAs: "com.loomo.harness")])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("Check \(\.$file)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let h = try loadHarness(file)
        let a = HarnessAnalysis(h)
        let errors = a.issues.filter { $0.severity == .error }.count
        let warnings = a.issues.filter { $0.severity == .warning }.count
        let headline = errors + warnings == 0 ? "\(h.name) passes every rule check." : "\(h.name) has \(errors) errors and \(warnings) warnings."
        return .result(value: HarnessScript.issues(of: h, analysis: a), dialog: "\(headline)")
    }
}

struct SummarizeHarnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Harness"
    static let description = IntentDescription("Describes a harness: connectors with free cavities, splices, bundles, wires and lengths.",
                                               categoryName: "Harness")

    @Parameter(title: "Harness", supportedContentTypes: [UTType(exportedAs: "com.loomo.harness")])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("Summarize \(\.$file)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: HarnessScript.summary(of: try loadHarness(file)))
    }
}

struct ExportDrawingSetIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Drawing Set"
    static let description = IntentDescription("Makes the PDF drawing set for a harness: drawing, connector faces, tables, BOM and notes.",
                                               categoryName: "Export")

    @Parameter(title: "Harness", supportedContentTypes: [UTType(exportedAs: "com.loomo.harness")])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("Export the drawing set for \(\.$file)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let h = try loadHarness(file)
        let pdf = PDFDrawingSet.make(h, library: LibraryStore.shared.library)
        return .result(value: IntentFile(data: pdf, filename: outputName(file, "pdf"), type: .pdf))
    }
}

struct ExportWorkbookIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Manufacturing Workbook"
    static let description = IntentDescription("Makes the Excel workbook for a harness: BOM, cut list, connection tables and more.",
                                               categoryName: "Export")

    @Parameter(title: "Harness", supportedContentTypes: [UTType(exportedAs: "com.loomo.harness")])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("Export the workbook for \(\.$file)") }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let h = try loadHarness(file)
        let data = HarnessAnalysis(h).workbook(for: h).data()
        return .result(value: IntentFile(data: data, filename: outputName(file, "xlsx"), type: UTType(filenameExtension: "xlsx") ?? .data))
    }
}

struct ExportWireVizIntent: AppIntent {
    static let title: LocalizedStringResource = "Export WireViz YAML"
    static let description = IntentDescription("Makes a WireViz YAML file for a harness.", categoryName: "Export")

    @Parameter(title: "Harness", supportedContentTypes: [UTType(exportedAs: "com.loomo.harness")])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("Export WireViz YAML for \(\.$file)") }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let h = try loadHarness(file)
        let yaml = Data(WireVizExport.yaml(for: h).utf8)
        return .result(value: IntentFile(data: yaml, filename: outputName(file, "yml"), type: UTType(filenameExtension: "yml") ?? .plainText))
    }
}

struct LoomoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CheckHarnessIntent(),
                    phrases: ["Check a harness in \(.applicationName)", "Run the \(.applicationName) rule checker"],
                    shortTitle: "Check Harness", systemImageName: "checkmark.seal")
        AppShortcut(intent: SummarizeHarnessIntent(),
                    phrases: ["Summarize a harness in \(.applicationName)", "Describe a \(.applicationName) harness"],
                    shortTitle: "Summarize Harness", systemImageName: "text.alignleft")
        AppShortcut(intent: ExportDrawingSetIntent(),
                    phrases: ["Export a drawing set with \(.applicationName)", "Make a \(.applicationName) drawing PDF"],
                    shortTitle: "Export Drawing Set", systemImageName: "doc.richtext")
        AppShortcut(intent: ExportWorkbookIntent(),
                    phrases: ["Export a \(.applicationName) workbook"],
                    shortTitle: "Export Workbook", systemImageName: "tablecells")
    }
}
