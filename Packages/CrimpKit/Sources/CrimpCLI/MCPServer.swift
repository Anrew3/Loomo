import CrimpCore
import Foundation

/// `crimp mcp`: a Model Context Protocol server on stdin/stdout, so Claude (or any MCP client) can read and edit
/// harnesses. Messages are newline-delimited JSON-RPC 2.0, as the MCP stdio transport specifies; logs go to stderr.
///
/// Where an edit lands:
///   * Loomo is running → the harness open in Loomo, live, through the app's local bridge. Every edit is one
///     undo step there, so the change shows on the canvas at once and ⌘Z takes it back.
///   * Loomo isn't running, or the file isn't open in it → the `.loomo` file on disk, when `file` is given.
///
/// The tools are generated from `HarnessCommands.catalog`, so they always match the CLI.
final class MCPServer {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let serverVersion = "0.5.0"

    private let bridge = LiveBridgeClient()

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            handle(message)
        }
    }

    // MARK: JSON-RPC

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        // A message without an id is a notification: never answered.
        guard let id = message["id"] else { return }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            reply(id, [
                "protocolVersion": Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "loomo", "title": "Loomo", "version": Self.serverVersion],
                "instructions": Self.instructions,
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            reply(id, call(name, arguments))
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    // MARK: Tools

    static let instructions = """
        Loomo is a wire harness design app. These tools read and edit harnesses.
        IDs: connectors C1, C2…; loose terminals T1…; splices SP1…; wires W1…; bundle segments S1…; nodes N1….
        A wire end is C1:2 (connector C1, cavity 2) or SP1 (a splice). Sizes like 18awg or 0.5mm2; colours like red, RD or red/white;
        lengths like 6in or 152.4mm.
        When Loomo is open, edits apply live to the open harness (the frontmost one unless `document` names another), and each
        edit is one undo step the user can take back. Call list_documents to see what's open and describe_harness before editing.
        Never invent part numbers or cavity counts; ask the user. After a batch of edits, call check_harness and report errors.
        """

    /// MCP tool name for a command ("add-wire" → "add_wire"), with friendlier names for the read and catch-all commands.
    static func toolName(_ command: String) -> String {
        switch command {
        case "summary": "describe_harness"
        case "info": "get_harness"
        case "check": "check_harness"
        case "set": "set_harness_properties"
        case "remove": "remove_items"
        case "move": "move_item"
        default: command.replacingOccurrences(of: "-", with: "_")
        }
    }

    static func argumentName(_ parameter: String) -> String { parameter.replacingOccurrences(of: "-", with: "_") }

    private static let targetProperties: [String: Any] = [
        "document": ["type": "string", "description": "Which open harness in Loomo: its name or file path (default: the frontmost)"],
        "file": ["type": "string", "description": "Path to a .loomo file. Edited live if it's open in Loomo, otherwise on disk."],
    ]

    static let tools: [[String: Any]] = {
        var list: [[String: Any]] = [
            [
                "name": "list_documents",
                "title": "List open harnesses",
                "description": "The harnesses open in Loomo right now, with which one is frontmost (active) and their size. Empty when Loomo isn't running.",
                "inputSchema": ["type": "object", "properties": [String: Any]()],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "open_harness",
                "title": "Open a harness in Loomo",
                "description": "Open a .loomo file in Loomo (launching it if needed) so edits show live. Use create to make a new, empty harness at that path first.",
                "inputSchema": ["type": "object", "required": ["file"], "properties": [
                    "file": ["type": "string", "description": "Path to the .loomo file"],
                    "create": ["type": "boolean", "description": "Create a new empty harness at this path first"],
                    "name": ["type": "string", "description": "Name for a new harness"],
                ] as [String: Any]],
                "annotations": ["readOnlyHint": false, "destructiveHint": false],
            ],
        ]
        for c in HarnessCommands.catalog {
            var properties = targetProperties
            var required: [String] = []
            for p in c.parameters {
                var schema: [String: Any] = ["description": p.summary]
                switch p.kind {
                case .text: schema["type"] = "string"
                case .number: schema["type"] = "number"
                case .integer: schema["type"] = "integer"
                case .flag, .boolean: schema["type"] = "boolean"
                case let .choice(values): schema["type"] = "string"; schema["enum"] = values
                case .list: schema["type"] = "array"; schema["items"] = ["type": "string"]
                }
                properties[argumentName(p.name)] = schema
                if p.required { required.append(argumentName(p.name)) }
            }
            var input: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { input["required"] = required }
            list.append([
                "name": toolName(c.name),
                "title": toolName(c.name).split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " "),
                "description": c.summary,
                "inputSchema": input,
                "annotations": ["readOnlyHint": !c.edits, "destructiveHint": c.name == "remove", "idempotentHint": !c.edits],
            ])
        }
        return list
    }()

    /// MCP arguments → the text options the command engine takes.
    static func options(for command: HarnessCommands.Command, _ arguments: [String: Any]) throws -> HarnessCommands.Options {
        var o = HarnessCommands.Options()
        for p in command.parameters {
            guard let value = arguments[argumentName(p.name)], !(value is NSNull) else { continue }
            switch p.kind {
            case .flag:
                if (value as? Bool) == true { o.flags.insert(p.name) }
            case .boolean:
                o.values[p.name] = (value as? Bool) == true ? "true" : "false"
            case .integer:
                if let n = value as? NSNumber { o.values[p.name] = String(n.intValue) } else { o.values[p.name] = "\(value)" }
            case .list:
                if let items = value as? [Any] { o.values[p.name] = items.map { "\($0)" }.joined(separator: ",") } else { o.values[p.name] = "\(value)" }
            case .number:
                if let n = value as? NSNumber { o.values[p.name] = n.stringValue } else { o.values[p.name] = "\(value)" }
            case .text, .choice:
                o.values[p.name] = value as? String ?? "\(value)"
            }
        }
        let known = Set(command.parameters.map { argumentName($0.name) } + ["document", "file"])
        if let unknown = arguments.keys.first(where: { !known.contains($0) }) {
            throw EditError.invalid("\(toolName(command.name)) has no argument \(unknown)")
        }
        return o
    }

    private func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "list_documents":
                let docs = bridge.isRunning ? try bridge.documents() : []
                return Self.result(["loomoRunning": bridge.isRunning, "documents": docs])
            case "open_harness":
                return Self.result(try openHarness(arguments))
            default:
                guard let command = HarnessCommands.catalog.first(where: { Self.toolName($0.name) == name }) else {
                    throw EditError.invalid("Unknown tool \(name)")
                }
                let o = try Self.options(for: command, arguments)
                let out = try run(command, o, document: arguments["document"] as? String, file: arguments["file"] as? String)
                if command.name == "summary", let text = (out["result"] as? [String: Any])?["summary"] as? String {
                    return ["content": [["type": "text", "text": "[\(out["mode"] ?? "")] \(out["document"] ?? "")\n" + text]]]
                }
                return Self.result(out)
            }
        } catch {
            return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
        }
    }

    static func result(_ object: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
    }

    /// Runs a command live in Loomo when the target is open there, otherwise on the file.
    private func run(_ command: HarnessCommands.Command, _ o: HarnessCommands.Options, document: String?, file: String?) throws -> [String: Any] {
        let path = file.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        if bridge.isRunning {
            let docs = try bridge.documents()
            let wanted = path ?? document
            let open = wanted == nil ? docs.first { $0["active"] as? Bool == true } ?? docs.first
                : docs.first { ($0["file"] as? String) == wanted || ($0["name"] as? String) == wanted }
            if let open, let id = open["id"] as? String {
                var out = try bridge.run(command.name, o, document: id)
                out["mode"] = "live"
                return out
            }
            if path == nil {
                throw EditError.invalid(docs.isEmpty ? "No harness is open in Loomo. Open one, or call open_harness with a file."
                                                     : "No open harness called \(wanted ?? ""). Open: \(docs.compactMap { $0["name"] as? String }.joined(separator: ", "))")
            }
        }
        guard let path else {
            throw EditError.invalid("Loomo isn't running. Open a harness in Loomo, or pass file with a .loomo path.")
        }
        // On disk: load, run, save (only when something changed).
        guard let data = FileManager.default.contents(atPath: path) else { throw EditError.invalid("Can't read \(path)") }
        let before = try Harness.load(from: data)
        var h = before
        var result = try HarnessCommands.run(command.name, o, on: &h, library: commandLibrary())
        if command.edits, h != before {
            try h.jsonData().write(to: URL(fileURLWithPath: path), options: .atomic)
            result.merge(HarnessCommands.checkCounts(h)) { a, _ in a }
        }
        return ["mode": "file", "document": path, "result": result]
    }

    private func openHarness(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let raw = arguments["file"] as? String else { throw EditError.invalid("file is required") }
        let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
        if (arguments["create"] as? Bool) == true {
            guard !FileManager.default.fileExists(atPath: path) else { throw EditError.invalid("\(path) already exists") }
            let name = arguments["name"] as? String ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            try Harness(name: name, revision: "A").jsonData().write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        guard FileManager.default.fileExists(atPath: path) else { throw EditError.invalid("\(path) doesn't exist; pass create: true to make it") }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", "com.loomo.Loomo", path]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else { throw EditError.invalid("Couldn't open \(path) in Loomo (is Loomo installed?)") }
        // Wait for the window, so the next tool call edits it live.
        for _ in 0..<40 {
            if bridge.isRunning, let docs = try? bridge.documents(), docs.contains(where: { ($0["file"] as? String) == path }) {
                return ["opened": path, "live": true]
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return ["opened": path, "live": false, "note": "Loomo didn't report the window within 10 s; edits will go to the file."]
    }
}

/// Talks to Loomo's live bridge: a Unix-domain socket only this user can open. One JSON line each way per request.
final class LiveBridgeClient {
    /// The first socket a running Loomo answers on: App Group, direct-download app, or sandboxed app.
    /// Looked up on every call, since Loomo may start (or quit) while the MCP server runs.
    private var socketPath: String? {
        SharedStorage.liveSocketCandidates.map(\.path).first { path in
            FileManager.default.fileExists(atPath: path) && (try? request(["method": "ping"], at: path)) != nil
        }
    }

    var isRunning: Bool { socketPath != nil }

    func documents() throws -> [[String: Any]] {
        try request(["method": "documents"])["documents"] as? [[String: Any]] ?? []
    }

    func run(_ command: String, _ o: HarnessCommands.Options, document: String) throws -> [String: Any] {
        try request(["method": "run", "params": [
            "document": document, "command": command,
            "values": o.values, "flags": Array(o.flags), "positional": o.positional,
        ] as [String: Any]])
    }

    func request(_ body: [String: Any]) throws -> [String: Any] {
        guard let path = socketPath else { throw EditError.invalid("Loomo isn't running") }
        return try request(body, at: path)
    }

    private func request(_ body: [String: Any], at path: String) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EditError.invalid("Can't open a socket") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw EditError.invalid("Socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw EditError.invalid("Loomo isn't running") }
        var payload = try JSONSerialization.data(withJSONObject: body)
        payload.append(0x0A)
        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, payload.count) }
        guard written == payload.count else { throw EditError.invalid("Couldn't reach Loomo") }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !response.contains(0x0A) {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            response.append(contentsOf: buffer[0..<n])
        }
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw EditError.invalid("Loomo sent an unreadable reply")
        }
        if object["ok"] as? Bool == false { throw EditError.invalid(object["error"] as? String ?? "Loomo refused the edit") }
        return object
    }
}
