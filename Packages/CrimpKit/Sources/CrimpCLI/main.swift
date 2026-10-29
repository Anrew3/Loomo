import CrimpCore
import CrimpOutputs
import Foundation
import PartsClient

// crimp: create, edit and check Loomo harness files (.loomo) from the command line.
// Every command prints one JSON object on stdout, so scripts and MCP servers can drive it.
// It uses the same engine as the app, so IDs, lengths and rule checks match exactly.

let usage = """
crimp: edit and check Loomo harness files. Output is JSON.

  crimp new <file> [--name N] [--revision A] [--units metric|imperial] [--allowance 20mm]
  crimp info <file>                    Everything in the harness, with computed wire lengths
  crimp validate <file>                Rule check; exit 1 when there are errors
  crimp set <file> [--name N] [--revision A] [--units metric|imperial] [--allowance LEN]

  crimp add-connector <file> --mpn MPN [--manufacturer M] [--description D] [--cavities N]
                      [--id C1] [--name N] [--kind housing|ringTerminal|spadeTerminal|ferrule|quickConnect|pigtail|device]
                      [--gender male|female] [--sealed] [--x X --y Y] [--no-library]
                      [--lookup]   (distributor data; keys from MOUSER_API_KEY, DIGIKEY_CLIENT_ID… in the environment)
  crimp add-splice <file> [--id SP1] [--kind ultrasonic|crimp|solderSleeve|inlineDiode|inlineResistor]
                      [--at NODE|C1|SP1] [--x X --y Y]
  crimp add-node <file> --kind breakout|clip [--x X --y Y] [--label L]
  crimp add-bundle <file> --from C1|SP1|N3 --to C2|SP1|N4 [--length 6in]
  crimp add-wire <file> --from C1:2|SP1 --to C2:1|SP1 [--id W2] [--size 18awg|0.5mm2] [--color red|RD/WH]
                      [--signal S] [--insulation TXL] [--double-crimp] [--no-bundle]
  crimp set-part <file> --connector C1 --mpn MPN [--manufacturer M] [--description D]
                      [--cavity 2|1,3|used|unused --role terminal|seal|plug]
                      [--min-wire 0.5 --max-wire 0.75] (mm², terminals)  [--min-od 1.2mm --max-od 1.6mm] (seals)
                      [--strip 4mm] [--crimp-tool TOOL]
  crimp set-cavity <file> --connector C1 --cavity 2 [--signal S] [--double-crimp true|false]
  crimp set-wire <file> --wire W2 [--signal S] [--size …] [--color …] [--insulation …] [--extra LEN] [--length LEN]
  crimp accept <file> --subject C3:2 --reason WHY [--match TEXT] [--by NAME]
                                       Accept the open checks on a subject as a reviewed deviation
  crimp unaccept <file> --subject C3:2 [--match TEXT]
  crimp add-fuse-box <file> --fuses N [--rating "15 A"] [--x X --y Y]
                                       Fuse holder: fuse Fk spans cavities 2k-1 and 2k
  crimp add-relay <file> [--rating "12 V 40 A"] [--x X --y Y]
                                       ISO relay socket: cavities 30, 85, 86, 87, 87a
  crimp add-loose-pins <file> --count N [--x X --y Y]
                                       Pins with no housing, to be pinned in later
  crimp add-mated-pair <file> --cavities N [--x X --y Y]
                                       In-line pair C5F/C5M; each cavity passes through to its mate
  crimp mate <file> --a C3 --b C4      Mate two connectors in line (--b none unmates)
  crimp pass-through <file> --from C1 --to C2 [--size 20awg] [--color BK] [--by-order] [--include-used]
                                       Wire each cavity of C1 to the same cavity of C2 (T-harness)
  crimp pdf <file> --out set.pdf [--pages harness,bom,…] [--no-side-tables]
  crimp formboard <file> --out board.pdf [--paper letter|tabloid|a4|a3] [--portrait] [--overlap 10mm]
                      [--single-sheet] [--no-map]
  crimp rename-connector <file> --connector C3 --to C9
  crimp rename-cavity <file> --connector C1 --cavity 1 --to A
  crimp move <file> --id C1|SP1|N3 --x X --y Y
  crimp remove <file> <id>…            Connectors, splices, wires, nodes, segments…
  crimp format <file>                  Rewrite in canonical form
  crimp schema                         Print the JSON Schema path
  crimp mcp                            Run as an MCP server on stdin/stdout (for Claude and other LLM clients).
                                       Edits the harness open in Loomo live, or a file when Loomo isn't running.

Lengths take a unit: 152.4mm, 6in, 0.5ft (plain numbers are mm).
"""

// MARK: - Output

/// `value ?? NSNull()` for JSON output: a missing value prints as null.
func ?? <T>(value: T?, null: NSNull) -> Any {
    if let value { return value }
    return null
}

func emit(_ object: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    emit(["ok": false, "error": message])
    exit(code)
}

// MARK: - Arguments

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let flagNames: Set<String> = ["sealed", "no-library", "lookup", "double-crimp", "no-bundle", "portrait",
                                         "single-sheet", "no-map", "no-side-tables", "by-order", "include-used"]

    init(_ raw: ArraySlice<String>) {
        var it = raw.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    options[String(name[..<eq])] = String(name[name.index(after: eq)...])
                } else if Self.flagNames.contains(name) {
                    flags.insert(name)
                } else if let v = it.next() {
                    options[name] = v
                } else {
                    fail("--\(name) needs a value")
                }
            } else {
                positional.append(a)
            }
        }
    }

    /// The same arguments in the form the shared command engine takes.
    var commandOptions: HarnessCommands.Options {
        HarnessCommands.Options(values: options, flags: flags, positional: Array(positional.dropFirst()))
    }

    subscript(_ key: String) -> String? { options[key] }
    func has(_ flag: String) -> Bool { flags.contains(flag) }

    func double(_ key: String) -> Double? {
        guard let v = options[key] else { return nil }
        guard let d = Double(v) else { fail("--\(key) must be a number, got \(v)") }
        return d
    }

    func int(_ key: String) -> Int? {
        guard let v = options[key] else { return nil }
        guard let i = Int(v) else { fail("--\(key) must be a whole number, got \(v)") }
        return i
    }

    func length(_ key: String) -> Double? { options[key].map { parseLength($0, key: key) } }

    func choice<T: RawRepresentable & CaseIterable>(_ key: String, _ type: T.Type) -> T? where T.RawValue == String {
        guard let v = options[key] else { return nil }
        guard let t = T.allCases.first(where: { $0.rawValue.lowercased() == v.lowercased() }) else {
            fail("--\(key) must be one of \(T.allCases.map(\.rawValue).joined(separator: ", ")), got \(v)")
        }
        return t
    }
}

// Parsing lives in CrimpCore.HarnessScript, shared with the app's assistant and Shortcuts actions.
func parseLength(_ s: String, key: String) -> Double {
    do { return try HarnessScript.length(s) } catch { fail("--\(key): \(error.localizedDescription)") }
}

func parseSize(_ s: String) -> WireSize {
    do { return try HarnessScript.wireSize(s) } catch { fail(error.localizedDescription) }
}

func parseColor(_ s: String) -> WireColor {
    do { return try HarnessScript.wireColor(s) } catch { fail(error.localizedDescription) }
}

// MARK: - Files

/// "wires[0].from.splice" rather than "wires.Index 0.from.splice".
func where_(_ path: [CodingKey]) -> String {
    path.reduce("") { out, key in
        if let i = key.intValue { return out + "[\(i)]" }
        return out.isEmpty ? key.stringValue : out + "." + key.stringValue
    }
}

func load(_ path: String) -> Harness {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else { fail("Can't read \(path)") }
    do { return try Harness.load(from: data) } catch let DecodingError.dataCorrupted(ctx) {
        fail("\(path) is not a valid harness: \(ctx.debugDescription) at \(where_(ctx.codingPath))")
    } catch let DecodingError.keyNotFound(key, ctx) {
        fail("\(path) is missing \(key.stringValue) at \(where_(ctx.codingPath))")
    } catch let DecodingError.typeMismatch(_, ctx) {
        fail("\(path) has the wrong type at \(where_(ctx.codingPath)): \(ctx.debugDescription)")
    } catch {
        fail("\(path) is not a valid harness: \(error.localizedDescription)")
    }
}

func save(_ h: Harness, _ path: String) {
    do { try h.jsonData().write(to: URL(fileURLWithPath: path), options: .atomic) } catch { fail("Can't write \(path): \(error.localizedDescription)") }
}

/// Loads, edits, saves and reports. The edit returns the fields to print.
func edit(_ path: String, _ change: (inout Harness) throws -> [String: Any]) {
    var h = load(path)
    do {
        var result = try change(&h)
        save(h, path)
        let a = HarnessAnalysis(h)
        result["ok"] = true
        result["errors"] = a.issues.filter { $0.severity == .error }.count
        result["warnings"] = a.issues.filter { $0.severity == .warning }.count
        emit(result)
    } catch {
        fail(error.localizedDescription)
    }
}

// MARK: - Reports (shared with the MCP server and the app: CrimpCore.HarnessReport)

func info(_ h: Harness) -> [String: Any] {
    var d = HarnessReport.info(h)
    d["ok"] = true
    return d
}

// MARK: - Library and distributor lookup

/// The user's parts library, which supplies cavity counts, photos and terminals for known parts.
func commandLibrary() -> PartLibrary? {
    let url = PartLibrary.defaultURL
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return PartLibrary.load(from: url)
}

/// Looks a part up with the built-in parts engine. The CLI can't read the app's Keychain, so it takes API keys from
/// the environment (MOUSER_API_KEY, DIGIKEY_CLIENT_ID/_SECRET, TRUSTEDPARTS_API_KEY, OEMSECRETS_API_KEY,
/// NEXAR_CLIENT_ID/_SECRET); without any it still answers from the parts database the app has built up.
/// Blocks on purpose: top-level `await` would run the whole tool on a small async-task stack,
/// which decoding a large harness overflows.
func lookUp(_ mpn: String) -> PartSummary? {
    let env = ProcessInfo.processInfo.environment
    var s = PartsSettings()
    s.mouserKey = env["MOUSER_API_KEY"] ?? ""
    s.digikeyClientID = env["DIGIKEY_CLIENT_ID"] ?? ""
    s.digikeyClientSecret = env["DIGIKEY_CLIENT_SECRET"] ?? ""
    s.trustedPartsKey = env["TRUSTEDPARTS_API_KEY"] ?? ""
    s.trustedPartsCompanyID = env["TRUSTEDPARTS_COMPANY_ID"] ?? ""
    s.oemsecretsKey = env["OEMSECRETS_API_KEY"] ?? ""
    s.nexarClientID = env["NEXAR_CLIENT_ID"] ?? ""
    s.nexarClientSecret = env["NEXAR_CLIENT_SECRET"] ?? ""
    final class Box: @unchecked Sendable { var part: PartSummary? }
    let box = Box(), done = DispatchSemaphore(value: 0)
    Task.detached {
        await PartsEngine.shared.configure(s)
        box.part = await PartsEngine.shared.detail(mpn: mpn).part
        done.signal()
    }
    done.wait()
    return box.part
}

// MARK: - Commands

var argv = CommandLine.arguments.dropFirst()
guard let command = argv.first else { print(usage); exit(0) }
argv = argv.dropFirst()
let args = Args(argv)
func file() -> String {
    guard let f = args.positional.first else { fail("Give the harness file, e.g. crimp \(command) harness.loomo") }
    return f
}
func point(_ h: Harness) -> Point2D {
    if let x = args.double("x"), let y = args.double("y") { return Point2D(x, y) }
    return HarnessScript.defaultPoint(in: h)
}

switch command {
case "help", "--help", "-h":
    print(usage)

case "schema":
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let candidates = [exe.deletingLastPathComponent().appendingPathComponent("../Resources/loomo.schema.json"),
                      exe.deletingLastPathComponent().appendingPathComponent("../../../Schemas/loomo.schema.json")]
    let found = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    emit(["ok": found != nil, "schema": found?.standardizedFileURL.path ?? NSNull(), "id": "https://raw.githubusercontent.com/Anrew3/Loomo/main/Schemas/loomo.schema.json"])

case "new":
    let path = file()
    if FileManager.default.fileExists(atPath: path) { fail("\(path) already exists") }
    var h = Harness(name: args["name"] ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                    revision: args["revision"] ?? "A")
    if let u = args.choice("units", UnitSystem.self) { h.settings.units = u }
    if let a = args.length("allowance") { h.settings.terminationAllowanceMM = a }
    save(h, path)
    emit(["ok": true, "file": path, "name": h.name])

case "info":
    emit(info(load(file())))

case "validate":
    let h = load(file())
    let a = HarnessAnalysis(h)
    let errors = a.issues.filter { $0.severity == .error }.count
    emit(["ok": errors == 0, "errors": errors, "warnings": a.issues.filter { $0.severity == .warning }.count,
          "accepted": a.issues.filter { $0.acceptedReason != nil }.count, "issues": HarnessReport.issues(a)])
    exit(errors == 0 ? 0 : 1)

case "format":
    let path = file()
    save(load(path), path)
    emit(["ok": true, "file": path])

case "add-connector" where args.has("lookup"):
    // Distributor data fills what the parts library doesn't know, including the cavity count.
    var o = args.commandOptions
    let mpn = o["mpn"] ?? ""
    let found = mpn.isEmpty || mpn.uppercased() == "GENERIC" ? nil : lookUp(mpn)
    if o["cavities"] == nil, let n = found?.partRef.positionCount { o.values["cavities"] = String(n) }
    edit(file()) { h in
        var result = try HarnessCommands.run("add-connector", o, on: &h, library: commandLibrary())
        guard let id = result["created"] as? String, let i = h.connectors.firstIndex(where: { $0.id == id }) else { return result }
        if let fresh = found?.partRef, var part = h.connectors[i].part {
            part.imageURL = part.imageURL ?? fresh.imageURL
            part.datasheetURL = part.datasheetURL ?? fresh.datasheetURL
            part.description = part.description ?? fresh.description
            part.positionCount = part.positionCount ?? fresh.positionCount
            part.rowCount = part.rowCount ?? fresh.rowCount
            part.pitchMM = part.pitchMM ?? fresh.pitchMM
            part.contactGender = part.contactGender ?? fresh.contactGender
            if part.manufacturer.isEmpty { part.manufacturer = fresh.manufacturer }
            h.connectors[i].part = part
            result["photo"] = part.imageURL?.absoluteString ?? NSNull()
        } else {
            result["note"] = "Distributor lookup found nothing (set API keys in the environment; see crimp help)"
        }
        return result
    }

case "pdf":
    let h = load(file())
    guard let out = args["out"] else { fail("Give the output file, e.g. --out drawing.pdf") }
    let pages = args["pages"].map { list in
        list.split(separator: ",").map { name -> DrawingPage in
            guard let p = DrawingPage(rawValue: String(name)) else { fail("Unknown page \(name); pages: \(DrawingPage.allCases.map(\.rawValue).joined(separator: ", "))") }
            return p
        }
    } ?? DrawingPage.allCases
    let data = PDFDrawingSet.make(h, pages: pages, tablesOnDrawingSheet: !args.has("no-side-tables"))
    do { try data.write(to: URL(fileURLWithPath: out)) } catch { fail(error.localizedDescription) }
    emit(["ok": true, "file": out, "bytes": data.count])

case "formboard":
    let h = load(file())
    guard let out = args["out"] else { fail("Give the output file, e.g. --out formboard.pdf") }
    var o = FormboardOptions()
    if let paper = args.choice("paper", SheetSize.self) { o.paper = paper }
    o.portrait = args.has("portrait")
    o.overlapMM = args.length("overlap") ?? 0
    o.layout = args.has("single-sheet") ? .singleSheet : .tiled
    o.assemblyMap = !args.has("no-map")
    let data = Formboard.make(h, options: o)
    do { try data.write(to: URL(fileURLWithPath: out)) } catch { fail(error.localizedDescription) }
    emit(["ok": true, "file": out, "bytes": data.count])

case "mcp":
    MCPServer().run()

case let name where HarnessCommands.command(name)?.edits == true:
    edit(file()) { h in try HarnessCommands.run(name, args.commandOptions, on: &h, library: commandLibrary()) }

default:
    fail("Unknown command \(command). Run crimp help.")
}
