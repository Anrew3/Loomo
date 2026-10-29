import AppKit
import CrimpCore
import MetricKit
import SwiftUI

/// Collects the crash, hang, CPU and disk-write reports macOS delivers through MetricKit and keeps them in
/// ~/Library/Logs/Loomo/Diagnostics, so problems like a crash on a particular page can be looked at later.
/// Reports usually arrive the next time the app runs after the problem.
final class DiagnosticsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = DiagnosticsCollector()

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Loomo/Diagnostics", isDirectory: true)
    }

    func start() {
        MXMetricManager.shared.add(self)
        save(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        save(payloads)
    }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        for p in payloads {
            let data = p.jsonRepresentation()
            let stamp = ISO8601DateFormatter().string(from: p.timeStampEnd).replacingOccurrences(of: ":", with: "-")
            let url = Self.folder.appendingPathComponent("diagnostic-\(stamp).json")
            if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url, options: .atomic) }
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .diagnosticsChanged, object: nil) }
    }

    /// Every saved report, newest first, with the file it came from.
    static func reports() -> [(summary: DiagnosticSummary, file: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .flatMap { url in DiagnosticSummary.summaries(fromPayload: (try? Data(contentsOf: url)) ?? Data()).map { ($0, url) } }
            .sorted { ($0.summary.date ?? .distantPast) > ($1.summary.date ?? .distantPast) }
    }
}

extension Notification.Name {
    static let diagnosticsChanged = Notification.Name("LoomoDiagnosticsChanged")
}

/// Help ▸ Diagnostic Reports.
struct DiagnosticsView: View {
    @State private var reports = DiagnosticsCollector.reports()
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            if reports.isEmpty {
                ContentUnavailableView("No problems reported", systemImage: "checkmark.seal",
                                       description: Text("If Loomo crashes or stops responding, macOS sends a report here, usually the next time the app opens."))
            } else {
                List(reports, id: \.summary.id, selection: $selection) { r in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(r.summary.kind)).foregroundStyle(r.summary.kind == .crash ? .red : .orange).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(r.summary.kind.rawValue).font(.headline)
                                Text([r.summary.date?.formatted(date: .abbreviated, time: .shortened), r.summary.appVersion.map { "v\($0)" }]
                                    .compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                            }
                            Text(r.summary.detail).textSelection(.enabled)
                            if !r.summary.appFrames.isEmpty {
                                Text(r.summary.appFrames.joined(separator: " → ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Show Report in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.file]) }
                        Button("Copy Report") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString((try? String(contentsOf: r.file, encoding: .utf8)) ?? "", forType: .string)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("Reports come from macOS (MetricKit) and stay on this Mac.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Folder") {
                    try? FileManager.default.createDirectory(at: DiagnosticsCollector.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(DiagnosticsCollector.folder)
                }
            }
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 320)
        .onReceive(NotificationCenter.default.publisher(for: .diagnosticsChanged)) { _ in reports = DiagnosticsCollector.reports() }
    }

    private func icon(_ k: DiagnosticSummary.Kind) -> String {
        switch k {
        case .crash: "xmark.octagon.fill"
        case .hang: "hourglass"
        case .cpu: "cpu"
        case .diskWrite: "internaldrive"
        case .launch: "timer"
        }
    }
}
