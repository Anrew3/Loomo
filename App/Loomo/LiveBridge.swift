import AppKit
import CrimpCore
import Darwin
import SwiftUI

/// Lets AI clients edit the harnesses open in Loomo, live. `crimp mcp` (the MCP server Claude launches) connects
/// to a Unix-domain socket in Application Support that only this user can open; nothing listens on the network.
/// Each edit runs the shared command engine (`HarnessCommands`, the same code as the CLI) on the main thread and
/// lands as one named undo step, so it appears on the canvas at once and ⌘Z takes it back.
///
/// Protocol: one JSON object per line each way.
///   {"method":"ping"}
///   {"method":"documents"}
///   {"method":"run","params":{"document":ID,"command":"add-wire","values":{…},"flags":[…],"positional":[…]}}
@MainActor
final class LiveBridge {
    static let shared = LiveBridge()
    static let enabledKey = "liveBridge.enabled"

    static var socketURL: URL { SharedStorage.liveSocket }

    /// The `crimp` tool inside this app, which MCP clients run as `crimp mcp`.
    static var crimpURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/crimp") }

    private struct Entry {
        let id = UUID().uuidString
        weak var doc: HarnessDocument?
        var url: URL?
        var lastActive = Date()
    }

    private var entries: [Entry] = []
    private var started = false

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    // MARK: Open documents

    func register(_ doc: HarnessDocument, url: URL?) {
        prune()
        if let i = entries.firstIndex(where: { $0.doc === doc }) {
            entries[i].url = url
        } else {
            entries.append(Entry(doc: doc, url: url))
        }
    }

    func activate(_ doc: HarnessDocument) {
        if let i = entries.firstIndex(where: { $0.doc === doc }) { entries[i].lastActive = Date() }
    }

    func unregister(_ doc: HarnessDocument) {
        entries.removeAll { $0.doc === doc || $0.doc == nil }
    }

    private func prune() { entries.removeAll { $0.doc == nil } }

    private func describe(_ e: Entry, active: Bool) -> [String: Any] {
        let h = e.doc?.harness ?? Harness()
        return ["id": e.id, "name": e.url?.deletingPathExtension().lastPathComponent ?? h.name,
                "harness": h.name, "revision": h.revision, "file": e.url?.standardizedFileURL.path ?? NSNull(),
                "active": active, "connectors": h.connectors.count, "wires": h.wires.count]
    }

    // MARK: Requests

    func respond(to request: [String: Any]) -> [String: Any] {
        let method = request["method"] as? String ?? ""
        if method == "ping" { return ["ok": true] }
        guard enabled else { return ["ok": false, "error": "AI editing is turned off in Loomo (Settings ▸ AI clients)."] }
        prune()
        switch method {
        case "documents":
            let newest = entries.max { $0.lastActive < $1.lastActive }?.id
            return ["ok": true, "documents": entries.map { describe($0, active: $0.id == newest) }]
        case "run":
            return run(request["params"] as? [String: Any] ?? [:])
        default:
            return ["ok": false, "error": "Unknown method \(method)"]
        }
    }

    private func run(_ params: [String: Any]) -> [String: Any] {
        guard let entry = entries.first(where: { $0.id == params["document"] as? String }), let doc = entry.doc else {
            return ["ok": false, "error": "That harness is no longer open."]
        }
        guard let name = params["command"] as? String, let command = HarnessCommands.command(name) else {
            return ["ok": false, "error": "Unknown command \(params["command"] ?? "")"]
        }
        let options = HarnessCommands.Options(values: params["values"] as? [String: String] ?? [:],
                                              flags: Set(params["flags"] as? [String] ?? []),
                                              positional: params["positional"] as? [String] ?? [])
        var h = doc.harness
        do {
            var result = try HarnessCommands.run(name, options, on: &h, library: LibraryStore.shared.library)
            if command.edits, h != doc.harness {
                doc.perform(Self.undoName(name)) { $0 = h }
                select(result, in: doc)
                result.merge(HarnessCommands.checkCounts(h)) { a, _ in a }
            }
            return ["ok": true, "document": describe(entry, active: true)["name"] ?? "", "result": result]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    /// "add-wire" → "Add Wire (AI)", so Edit ▸ Undo says what it will take back.
    static func undoName(_ command: String) -> String {
        command.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") + " (AI)"
    }

    /// Selects what an edit just made, so the user can see it on the drawing.
    private func select(_ result: [String: Any], in doc: HarnessDocument) {
        guard let id = (result["created"] ?? result["connector"]) as? String else { return }
        let h = doc.harness
        if h.connector(id) != nil { doc.selection = .connector(id) }
        else if h.wire(id) != nil { doc.selection = .wire(id) }
        else if h.splice(id) != nil { doc.selection = .splice(id) }
        else if h.segment(id) != nil { doc.selection = .segment(id) }
        else if h.node(id) != nil { doc.selection = .node(id) }
    }

    // MARK: Socket

    /// Starts listening. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        let url = Self.socketURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        unlink(path)  // A socket left by a previous run.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        chmod(path, 0o600)  // Only this user.
        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                DispatchQueue.global(qos: .userInitiated).async { Self.serve(client) }
            }
        }
        thread.name = "Loomo live bridge"
        thread.start()
    }

    /// Reads one request line, answers it on the main thread, writes one reply line.
    nonisolated private static func serve(_ fd: Int32) {
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !data.contains(0x0A), data.count < 4_000_000 {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0..<n])
        }
        let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // The reply is built from plain values on the main thread and serialised here.
        let reply: Data = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                let object = LiveBridge.shared.respond(to: request)
                return (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
                    ?? Data(#"{"ok":false,"error":"Loomo couldn't encode the reply"}"#.utf8)
            }
        }
        var out = reply
        out.append(0x0A)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
    }

    // MARK: Client setup

    /// Adds Loomo to Claude Desktop's MCP servers, keeping everything else in its config.
    static func addToClaudeDesktop() throws -> URL {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: config), !data.isEmpty {
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: config.path])
            }
            root = existing
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["loomo"] = ["command": crimpURL.path, "args": ["mcp"]]
        root["mcpServers"] = servers
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: config, options: .atomic)
        return config
    }

    /// Loomo's entry for Claude Desktop's "mcpServers", for pasting by hand.
    static var claudeDesktopEntry: String {
        "\"loomo\": { \"command\": \"\(crimpURL.path)\", \"args\": [\"mcp\"] }"
    }

    /// The command that adds Loomo to Claude Code.
    static var claudeCodeCommand: String { "claude mcp add --scope user loomo -- \"\(crimpURL.path)\" mcp" }
}

/// Keeps the bridge's list of open harnesses current: registered while the window exists, most recent on top.
struct LiveRegistration: ViewModifier {
    let doc: HarnessDocument
    let url: URL?
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content
            .onAppear {
                LiveBridge.shared.register(doc, url: url)
                LiveBridge.shared.activate(doc)
            }
            .onChange(of: url) { LiveBridge.shared.register(doc, url: url) }
            .onChange(of: activeState) { if activeState == .key { LiveBridge.shared.activate(doc) } }
            .onDisappear { LiveBridge.shared.unregister(doc) }
    }
}

/// Settings ▸ AI clients.
struct AIClientsSettings: View {
    @AppStorage(LiveBridge.enabledKey) private var enabled = true
    @State private var status: String?

    var body: some View {
        Section("AI clients") {
            Toggle("Let AI clients edit open harnesses", isOn: $enabled)
            Text("Claude and other MCP clients run Loomo's crimp tool to read and edit harnesses. Edits apply to the open window and each one is an undo step. Nothing is reachable from the network.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if SharedStorage.isSandboxed {
                    // The App Store build can't write another app's settings: hand the user the entry to paste.
                    Button("Copy Claude Desktop Setup") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(LiveBridge.claudeDesktopEntry, forType: .string)
                        status = "Copied. In Claude Desktop, open Settings ▸ Developer ▸ Edit Config and add it under \"mcpServers\"."
                    }
                } else {
                    Button("Add to Claude Desktop") {
                        do {
                            let url = try LiveBridge.addToClaudeDesktop()
                            status = "Added to \(url.lastPathComponent). Restart Claude Desktop to connect."
                        } catch {
                            status = "Couldn't update Claude Desktop's settings: \(error.localizedDescription)"
                        }
                    }
                }
                Button("Copy Claude Code Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(LiveBridge.claudeCodeCommand, forType: .string)
                    status = "Copied. Paste it in Terminal."
                }
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
