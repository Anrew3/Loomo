import CrimpCore
import FoundationModels
import SwiftUI

// The harness assistant: Apple's on-device model with tools that read and edit the open harness through
// CrimpCore.HarnessScript (the same operations as the crimp CLI). Nothing leaves the Mac. Every edit is
// one undo step, so ⌘Z takes back anything the assistant did.

/// One line in the conversation.
struct AssistantMessage: Identifiable, Equatable {
    enum Role { case user, assistant, edit, error }
    let id = UUID()
    let role: Role
    var text: String
}

@MainActor
final class HarnessAssistant: ObservableObject {
    @Published private(set) var messages: [AssistantMessage] = []
    @Published private(set) var responding = false
    private weak var doc: HarnessDocument?
    private var session: LanguageModelSession?
    private var task: Task<Void, Never>?

    var availability: SystemLanguageModel.Availability { SystemLanguageModel.default.availability }

    func attach(_ doc: HarnessDocument) { self.doc = doc }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !responding, let doc else { return }
        messages.append(AssistantMessage(role: .user, text: prompt))
        responding = true
        let session = self.session ?? makeSession(for: doc)
        self.session = session
        task = Task {
            do {
                let reply = try await session.respond(to: prompt)
                messages.append(AssistantMessage(role: .assistant, text: reply.content))
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error {
                    // The on-device model has a small context; start fresh with the current harness.
                    self.session = nil
                    messages.append(AssistantMessage(role: .error, text: "The conversation got too long, so I started a new one. Please ask again."))
                } else {
                    messages.append(AssistantMessage(role: .error, text: error.localizedDescription))
                }
            } catch {
                messages.append(AssistantMessage(role: .error, text: error.localizedDescription))
            }
            responding = false
        }
    }

    func stop() {
        task?.cancel()
        responding = false
    }

    func clear() {
        stop()
        messages = []
        session = nil
    }

    /// Called by the tools on the main actor: applies one edit as an undo step and reports it.
    fileprivate func edit(_ name: String, _ change: (inout Harness) throws -> String) -> String {
        guard let doc else { return "Error: the harness window was closed." }
        var copy = doc.harness
        do {
            let result = try change(&copy)
            doc.perform(name) { $0 = copy }
            messages.append(AssistantMessage(role: .edit, text: result))
            return result
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    fileprivate func read(_ body: (Harness) -> String) -> String {
        guard let doc else { return "Error: the harness window was closed." }
        return body(doc.harness)
    }

    /// New items go to the right of the drawing, never on top of existing parts.
    fileprivate func nextPoint() -> Point2D {
        guard let doc else { return Point2D(120, 240) }
        return HarnessScript.defaultPoint(in: doc.harness)
    }

    private func makeSession(for doc: HarnessDocument) -> LanguageModelSession {
        let box = AssistantBox(self)
        let tools: [any Tool] = [
            DescribeHarnessTool(box: box), ListIssuesTool(box: box), AddConnectorTool(box: box), AddSpliceTool(box: box),
            AddBundleTool(box: box), AddWireTool(box: box), SetCavitySignalTool(box: box), RenameConnectorTool(box: box),
            RemoveItemsTool(box: box),
        ]
        return LanguageModelSession(tools: tools, instructions: """
            You are the assistant in Loomo, a wire harness design app. You help design and check one harness.
            IDs: connectors C1, C2…; loose terminals T1…; splices SP1…; wires W1…; bundle segments S1…; nodes N1….
            A wire end is written C1:2 (connector C1, cavity 2) or SP1 (a splice).
            Wire sizes like 18awg or 0.5mm2; colours like red, RD or red/white.
            Use the tools to look at and change the harness. Call describe_harness before editing if you are unsure what exists.
            Never invent part numbers or cavity counts; ask the user when you don't know them.
            Keep replies short: say what you changed or found in one to three sentences.

            Current harness:
            \(HarnessScript.summary(of: doc.harness, maxWires: 25))
            """)
    }
}

/// Lets the tools (which run off the main actor, sometimes several at once) reach the assistant safely,
/// and runs their work strictly in the order the model asked for it, so "add C5, then wire C5:1" works.
final class AssistantBox: @unchecked Sendable {
    private weak var assistant: HarnessAssistant?
    private let lock = NSLock()
    private var last: Task<String, Never>?
    init(_ assistant: HarnessAssistant) { self.assistant = assistant }

    private func enqueue(_ work: @escaping @MainActor (HarnessAssistant) -> String) async -> String {
        let task: Task<String, Never> = lock.withLock {
            let previous = last
            let next = Task { @MainActor [weak assistant] in
                _ = await previous?.value
                guard let assistant else { return "Error: the assistant was closed." }
                return work(assistant)
            }
            last = next
            return next
        }
        return await task.value
    }

    func edit(_ name: String, _ change: @escaping @MainActor (inout Harness, Point2D) throws -> String) async -> String {
        await enqueue { a in
            let p = a.nextPoint()
            return a.edit(name) { try change(&$0, p) }
        }
    }

    func read(_ body: @escaping @MainActor (Harness) -> String) async -> String {
        await enqueue { $0.read(body) }
    }
}

// MARK: - Tools

struct DescribeHarnessTool: Tool {
    let box: AssistantBox
    let name = "describe_harness"
    let description = "Returns the harness: connectors with used and free cavities, splices, bundles, wires and rule-check counts."
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> String {
        await box.read { HarnessScript.summary(of: $0) }
    }
}

struct ListIssuesTool: Tool {
    let box: AssistantBox
    let name = "list_issues"
    let description = "Returns the rule checker's errors and warnings, one per line, with the item each is about."
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> String {
        await box.read { HarnessScript.issues(of: $0) }
    }
}

struct AddConnectorTool: Tool {
    let box: AssistantBox
    let name = "add_connector"
    let description = "Places a connector housing. Parts in the user's library bring their photo, terminals and seals."
    @Generable struct Arguments {
        @Guide(description: "Manufacturer part number, e.g. DT06-4S, or GENERIC for a placeholder")
        var mpn: String
        @Guide(description: "Manufacturer, if known")
        var manufacturer: String?
        @Guide(description: "Number of cavities; required unless the part is in the library")
        var cavities: Int?
        @Guide(description: "Optional descriptive name, e.g. ECU or Left headlamp")
        var name: String?
    }
    func call(arguments: Arguments) async throws -> String {
        await box.edit("Assistant: Add \(arguments.mpn)") { h, p in
            var spec = HarnessScript.ConnectorSpec(mpn: arguments.mpn, manufacturer: arguments.manufacturer, cavities: arguments.cavities)
            spec.name = arguments.name
            let (part, config) = HarnessScript.part(for: spec, library: LibraryStore.shared.library)
            let id = try HarnessScript.addConnector(spec, part: part, config: config, to: &h, at: p)
            return "Added \(id) (\(part.mpn), \(h.connector(id)?.cavities.count ?? 0) cavities)."
        }
    }
}

struct AddSpliceTool: Tool {
    let box: AssistantBox
    let name = "add_splice"
    let description = "Adds a splice. It can share the junction of an existing splice or node."
    @Generable struct Arguments {
        @Guide(description: "Optional: an existing splice or node id whose junction the new splice should share")
        var sameJunctionAs: String?
    }
    func call(arguments: Arguments) async throws -> String {
        await box.edit("Assistant: Add Splice") { h, p in
            var node: EntityID?
            if let ref = arguments.sameJunctionAs, !ref.isEmpty {
                guard let n = h.nodeID(for: ref) else { throw EditError.notFound(ref) }
                node = n
            }
            let id = h.addSplice(at: p, onNode: node)
            return "Added splice \(id)."
        }
    }
}

struct AddBundleTool: Tool {
    let box: AssistantBox
    let name = "add_bundle"
    let description = "Adds a bundle segment between two connectors, splices or nodes, which gives wires between them a length."
    @Generable struct Arguments {
        @Guide(description: "Connector, splice or node id at one end, e.g. C1")
        var from: String
        @Guide(description: "Connector, splice or node id at the other end, e.g. SP1")
        var to: String
        @Guide(description: "Optional length with unit, e.g. 300mm or 6in")
        var length: String?
    }
    func call(arguments: Arguments) async throws -> String {
        await box.edit("Assistant: Add Bundle") { h, _ in
            let id = try h.addSegment(from: arguments.from, to: arguments.to, lengthMM: try arguments.length.map(HarnessScript.length))
            return "Added bundle \(id) between \(arguments.from) and \(arguments.to) (\(h.settings.units.format(h.segment(id)?.lengthMM)))."
        }
    }
}

struct AddWireTool: Tool {
    let box: AssistantBox
    let name = "add_wire"
    let description = "Adds a wire between two ends. An end is a cavity like C1:2 or a splice like SP1."
    @Generable struct Arguments {
        @Guide(description: "First end, e.g. C1:2 or SP1")
        var from: String
        @Guide(description: "Second end, e.g. C2:1 or SP1")
        var to: String
        @Guide(description: "Optional size, e.g. 18awg or 0.5mm2 (default 20awg)")
        var size: String?
        @Guide(description: "Optional colour, e.g. red, RD or red/white (default black)")
        var color: String?
        @Guide(description: "Optional signal name, e.g. 12V, GND, CAN_H")
        var signal: String?
    }
    func call(arguments: Arguments) async throws -> String {
        await box.edit("Assistant: Add Wire") { h, _ in
            let id = try HarnessScript.addWire(from: arguments.from, to: arguments.to, size: arguments.size,
                                               color: arguments.color, signal: arguments.signal, in: &h)
            let w = h.wire(id)
            return "Added \(id): \(w?.from.description ?? arguments.from) → \(w?.to.description ?? arguments.to), \(w?.size.description ?? "") \(w?.color.description ?? "")."
        }
    }
}

struct SetCavitySignalTool: Tool {
    let box: AssistantBox
    let name = "set_cavity_signal"
    let description = "Names the signal on a connector cavity, e.g. C1 cavity 2 is CAN_H."
    @Generable struct Arguments {
        @Guide(description: "Connector id, e.g. C1")
        var connector: String
        @Guide(description: "Cavity label, e.g. 2 or A")
        var cavity: String
        @Guide(description: "Signal name")
        var signal: String
    }
    func call(arguments: Arguments) async throws -> String {
        await box.edit("Assistant: Set Signal") { h, _ in
            guard let i = h.connectors.firstIndex(where: { $0.id == arguments.connector }),
                  let k = h.connectors[i].cavities.firstIndex(where: { $0.label == arguments.cavity }) else {
                throw EditError.notFound("\(arguments.connector):\(arguments.cavity)")
            }
            h.connectors[i].cavities[k].signal = arguments.signal
            return "\(arguments.connector):\(arguments.cavity) is now \(arguments.signal)."
        }
    }
}

struct RenameConnectorTool: Tool {
    let box: AssistantBox
    let name = "rename_connector"
    let description = "Changes a connector's designator everywhere it is used, e.g. C5 to C3."
    @Generable struct Arguments {
        var from: String
        var to: String
    }
    func call(arguments: Arguments) async throws -> String {
        await box.edit("Assistant: Rename \(arguments.from)") { h, _ in
            guard h.connector(arguments.from) != nil else { throw EditError.notFound(arguments.from) }
            guard h.renameConnector(arguments.from, to: arguments.to) else { throw EditError.invalid("\(arguments.to) is already used") }
            return "Renamed \(arguments.from) to \(arguments.to)."
        }
    }
}

struct RemoveItemsTool: Tool {
    let box: AssistantBox
    let name = "remove_items"
    let description = "Deletes connectors, splices, wires, bundles or nodes by id. Only use when the user asks to remove something."
    @Generable struct Arguments {
        @Guide(description: "Ids to delete, e.g. [\"W3\", \"C2\"]")
        var ids: [String]
    }
    func call(arguments: Arguments) async throws -> String {
        await box.edit("Assistant: Delete") { h, _ in
            let known = arguments.ids.filter { id in
                h.connector(id) != nil || h.splice(id) != nil || h.wire(id) != nil || h.node(id) != nil || h.segment(id) != nil
            }
            guard !known.isEmpty else { throw EditError.invalid("None of \(arguments.ids.joined(separator: ", ")) exist") }
            h.delete(Set(known))
            return "Deleted \(known.joined(separator: ", "))."
        }
    }
}

// MARK: - Panel

struct AssistantView: View {
    @ObservedObject var assistant: HarnessAssistant
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "Summarise this harness",
        "Explain the rule-check issues",
        "Which cavities are still free?",
        "Add a DT06-2S as C5 and wire cavity 1 to SP1 in 18awg red",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Assistant").font(.headline)
                    Text("On-device · nothing leaves your Mac").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !assistant.messages.isEmpty {
                    Button { assistant.clear() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Start a new conversation")
                }
            }
            .padding(12)
            Divider()
            switch assistant.availability {
            case .available:
                conversation
                inputBar
            case .unavailable(let reason):
                ContentUnavailableView("Assistant unavailable", systemImage: "sparkles", description: Text(explanation(reason)))
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if assistant.messages.isEmpty {
                        Text("Ask about this harness or describe a change. Every edit can be undone with ⌘Z.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(suggestions, id: \.self) { s in
                            Button { assistant.send(s) } label: {
                                Text(s).font(.callout).multilineTextAlignment(.leading)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    ForEach(assistant.messages) { m in bubble(m).id(m.id) }
                    if assistant.responding {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                            .font(.callout).id("thinking")
                    }
                }
                .padding(12)
            }
            .onChange(of: assistant.messages) {
                withAnimation { proxy.scrollTo(assistant.messages.last?.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func bubble(_ m: AssistantMessage) -> some View {
        switch m.role {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(m.text).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
            }
        case .assistant:
            Text(m.text).textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .edit:
            Label(m.text, systemImage: "pencil.circle").font(.caption).foregroundStyle(.secondary)
        case .error:
            Label(m.text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask or describe a change…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit(send)
            if assistant.responding {
                Button { assistant.stop() } label: { Image(systemName: "stop.circle.fill") }
                    .buttonStyle(.borderless).help("Stop")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(10)
        .onAppear { inputFocused = true }
    }

    private func send() {
        assistant.send(draft)
        draft = ""
    }

    private func explanation(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "This Mac can't run Apple's on-device model."
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings to use the assistant."
        case .modelNotReady: "The on-device model is still downloading. Try again in a little while."
        @unknown default: "The on-device model isn't available right now."
        }
    }
}

extension Notification.Name {
    /// Shows or hides the assistant in the harness window whose document is the notification's object.
    static let toggleAssistant = Notification.Name("LoomoToggleAssistant")
}
