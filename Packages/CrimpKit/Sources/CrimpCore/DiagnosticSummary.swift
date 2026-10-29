import Foundation

/// A one-line reading of a MetricKit diagnostic report (crash, hang, CPU or disk-write exception), parsed
/// from the JSON macOS delivers. Kept here, free of MetricKit, so it can be tested with sample reports.
public struct DiagnosticSummary: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case crash = "Crash", hang = "Hang", cpu = "High CPU", diskWrite = "Disk writes", launch = "Slow launch" }

    public var id: String { "\(kind.rawValue)|\(date?.timeIntervalSince1970 ?? 0)|\(detail)" }
    public var kind: Kind
    public var date: Date?
    public var appVersion: String?
    /// Plain-language detail, e.g. "EXC_BREAKPOINT (SIGTRAP), Objective-C exception" or "Hung for 3.2 s".
    public var detail: String
    /// The first frames of the crashed or hung thread that are in Loomo code, when present.
    public var appFrames: [String]

    /// Reads every diagnostic in one MetricKit payload (`MXDiagnosticPayload.jsonRepresentation()`).
    public static func summaries(fromPayload data: Data) -> [DiagnosticSummary] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let date = (root["timeStampEnd"] as? String).flatMap(parseDate)
        let diagnostics = root["crashDiagnostics"] != nil ? root : (root["diagnostics"] as? [String: Any] ?? root)
        var out: [DiagnosticSummary] = []
        let kinds: [(String, Kind)] = [("crashDiagnostics", .crash), ("hangDiagnostics", .hang), ("cpuExceptionDiagnostics", .cpu),
                                       ("diskWriteExceptionDiagnostics", .diskWrite), ("appLaunchDiagnostics", .launch)]
        for (key, kind) in kinds {
            for d in diagnostics[key] as? [[String: Any]] ?? [] {
                let meta = d["diagnosticMetaData"] as? [String: Any] ?? [:]
                out.append(DiagnosticSummary(kind: kind, date: date, appVersion: meta["appVersion"] as? String,
                                             detail: detail(kind, meta), appFrames: frames(d["callStackTree"])))
            }
        }
        return out
    }

    private static func detail(_ kind: Kind, _ meta: [String: Any]) -> String {
        switch kind {
        case .crash:
            var parts: [String] = []
            if let type = meta["exceptionType"] { parts.append(exceptionName(type)) }
            if let signal = meta["signal"] { parts.append(signalName(signal)) }
            if let reason = meta["terminationReason"] as? String, !reason.isEmpty { parts.append(reason) }
            if let objc = (meta["objectiveCexceptionReason"] as? [String: Any])?["composedMessage"] as? String { parts.append(objc) }
            return parts.isEmpty ? "The app quit unexpectedly" : parts.joined(separator: ", ")
        case .hang:
            return "Not responding for \(meta["hangDuration"] as? String ?? "a while")"
        case .cpu:
            return "Used \(meta["totalCPUTime"] as? String ?? "a lot of CPU") over \(meta["totalSampledTime"] as? String ?? "a short time")"
        case .diskWrite:
            return "Wrote \(meta["writesCaused"] as? String ?? "a lot of data") to disk"
        case .launch:
            return "Took \(meta["launchDuration"] as? String ?? "a long time") to launch"
        }
    }

    private static func exceptionName(_ v: Any) -> String {
        let names = [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 10: "EXC_CRASH"]
        if let n = v as? Int { return names[n] ?? "exception \(n)" }
        return "\(v)"
    }

    private static func signalName(_ v: Any) -> String {
        let names = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV"]
        if let n = v as? Int { return names[n] ?? "signal \(n)" }
        return "\(v)"
    }

    /// Frames from Loomo binaries (app, extensions, crimp) on the first thread of the call stack tree.
    private static func frames(_ tree: Any?) -> [String] {
        guard let tree = tree as? [String: Any],
              let stack = (tree["callStacks"] as? [[String: Any]])?.first(where: { ($0["threadAttributed"] as? Bool) == true })
                ?? (tree["callStacks"] as? [[String: Any]])?.first else { return [] }
        var out: [String] = []
        var level = stack["callStackRootFrames"] as? [[String: Any]] ?? []
        while let frame = level.first, out.count < 8 {
            let image = frame["binaryName"] as? String ?? ""
            if image.hasPrefix("Loomo") || image == "crimp" {
                let offset = frame["offsetIntoBinaryTextSegment"].map { " +\($0)" } ?? ""
                out.append(image + offset)
            }
            level = frame["subFrames"] as? [[String: Any]] ?? []
        }
        return out
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }
}
