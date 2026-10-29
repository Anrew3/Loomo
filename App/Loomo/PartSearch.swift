import CrimpCore
import CrimpOutputs
import PartsClient
import SwiftUI

private struct DocumentKey: EnvironmentKey {
    static let defaultValue: HarnessDocument? = nil
}

extension EnvironmentValues {
    /// The document a part field belongs to; nil inside the library window.
    var harnessDocument: HarnessDocument? {
        get { self[DocumentKey.self] }
        set { self[DocumentKey.self] = newValue }
    }
}

/// A part slot. The search sheet looks in the team library first, then Octopart.
struct PartField: View {
    let title: String
    @Binding var part: PartRef?
    let category: PartCategory
    @Environment(\.harnessDocument) private var doc
    @EnvironmentObject private var library: LibraryStore
    @State private var searching = false
    @State private var replaceEverywhere = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(part.map { $0.isGeneric ? ($0.description ?? "Generic") : $0.mpn } ?? "None")
                        .foregroundStyle(part == nil ? Color.secondary : (part?.isGeneric == true ? Color.orange : Color.primary))
                    if let p = part, !p.isGeneric {
                        HStack(spacing: 4) {
                            Text([p.internalPN, p.manufacturer].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary)
                            SourceIcons(sources: p.dataSources)
                                .scaleEffect(0.85)
                        }
                    }
                }
                Menu {
                    Button("Search Library & Octopart…") { replaceEverywhere = false; searching = true }
                    if let p = part {
                        if let doc {
                            let n = doc.harness.usages(of: p).count
                            Button("Replace Everywhere (\(n) uses)…") { replaceEverywhere = true; searching = true }
                        }
                        if library.library.entry(for: p) == nil {
                            Button("Add to Library") { library.library.upsert(LibraryPart(part: p, category: category.rawValue)) }
                        }
                        if let url = p.datasheetURL { Link("Open Datasheet", destination: url) }
                        Divider()
                        Button("Clear", role: .destructive) { part = nil }
                    }
                } label: { Image(systemName: "magnifyingglass") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
        }
        .sheet(isPresented: $searching) {
            PartSearchView(category: category, replacing: replaceEverywhere ? part : nil) { picked in
                if replaceEverywhere, let old = part, let doc {
                    doc.perform("Replace \(old.mpn) with \(picked.mpn)") { $0.replacePart(old, with: picked) }
                } else {
                    part = picked
                }
                searching = false
            } cancel: { searching = false }
            .environmentObject(library)
        }
    }
}

struct PartSearchView: View {
    @EnvironmentObject var library: LibraryStore
    @State var category: PartCategory
    var replacing: PartRef?
    var title: String? = nil
    var initialSource: Source = .library
    /// Extra button shown at the bottom left (e.g. "Place Without Part").
    var secondaryAction: (title: String, action: () -> Void)? = nil
    var confirmTitle = "Use Part"
    /// Placing a component: what to place it as; nil means "work it out from the part".
    var placeAs: Binding<ConnectorKind?>? = nil
    let pick: (PartRef) -> Void
    let cancel: () -> Void

    /// Library, or distributor search with the user's own API keys (PartsEngine).
    enum Source: String, CaseIterable { case library = "Library", octopart = "Online" }
    @State private var source: Source?
    @State private var query = ""
    @State private var results: [PartSummary] = []
    @State private var resultSource = ""
    @State private var fallbackNote: String?
    @AppStorage("partsProvider") private var providerRaw = PartsProvider.auto.rawValue
    @State private var loading = false
    @State private var error: String?
    @State private var selectedOcto: PartSummary.ID?
    @State private var selectedLib: LibraryPart.ID?
    @State private var manual = PartRef(mpn: "", manufacturer: "")
    /// Cavity count chosen in the detail panel; overrides the distributor value (or supplies a missing one).
    @State private var cavities: Int?
    /// Results completed from the other sources (photo, positions, datasheet), keyed by result id.
    @State private var enriched: [PartSummary.ID: PartSummary] = [:]
    @State private var detailLoading: PartSummary.ID?
    @AppStorage(PartsService.customKey) private var backendURL = ""
    @FocusState private var searchFocused: Bool

    private var activeSource: Source { source ?? initialSource }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            searchBar
            if let r = replacing {
                Label("Replacing \(r.isGeneric ? (r.description ?? "generic part") : r.mpn) everywhere it is used", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .glassEffect(.regular.tint(.orange.opacity(0.6)), in: Capsule())
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .glassEffect(.regular.tint(.red.opacity(0.5)), in: Capsule())
            }

            HStack(spacing: 14) {
                Group {
                    if activeSource == .library { libraryTable } else { octopartTable }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassPanel(cornerRadius: 18)
                detailPanel
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)
                    .glassPanel(cornerRadius: 18)
            }

            DisclosureGroup {
                HStack {
                    TextField("MPN", text: $manual.mpn)
                    TextField("Manufacturer", text: $manual.manufacturer)
                    TextField("Description", text: $manual.description.orEmpty)
                    Toggle("Generic", isOn: $manual.isGeneric)
                    Button("Use") { pick(manual) }
                        .buttonStyle(.glass)
                        .disabled(manual.mpn.isEmpty && manual.description == nil)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 6)
            } label: {
                Label("Enter a part manually", systemImage: "square.and.pencil").font(.callout)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassCard(cornerRadius: 14)

            footer
        }
        .padding(20)
        .frame(width: 1040, height: 680)
        .background(AmbientBackground(tint: category.tint, intensity: 0.8))
        .onAppear {
            searchFocused = true
            preselectLibraryMatch()
        }
        .onChange(of: query) { preselectLibraryMatch() }
        .onChange(of: selectedOcto) { cavities = nil; fetchDetailIfNeeded() }
        .onChange(of: selectedLib) { cavities = nil }
        .onChange(of: category) { preselectLibraryMatch() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(systemName: category.icon, tint: category.tint, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? "Find a Part").font(.title2.weight(.semibold))
                Text(activeSource == .library ? "Your library first: parts you've used, with their terminals, seals and photos"
                                              : "Live distributor data from OEMsecrets, TrustedParts and Octopart")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            sourceSwitch
        }
    }

    /// Library / Online, as two glass chips that morph into each other.
    private var sourceSwitch: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(Source.allCases, id: \.self) { s in
                    let on = activeSource == s
                    Button {
                        withAnimation(.snappy) { source = s }
                        if s == .octopart, !query.isEmpty, results.isEmpty { search() }
                    } label: {
                        Label(s.rawValue, systemImage: s == .library ? "books.vertical.fill" : "globe")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(on ? .white : .secondary)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(on ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: Capsule())
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                TextField(activeSource == .library ? "Filter by MPN, internal PN or alternate…" : "Search by part number, e.g. DT06-4S or 282080-1",
                          text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit {
                        // Return searches online, or takes the highlighted library part.
                        if activeSource == .octopart { search() } else if let p = chosen { pick(p) }
                    }
                if loading { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .glassEffect(.regular, in: Capsule())

            Menu {
                Picker("Category", selection: $category) {
                    ForEach(PartCategory.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(category.title, systemImage: category.icon).font(.callout.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .glassEffect(.regular.interactive(), in: Capsule())
            .help("Part category")

            if activeSource == .octopart {
                Menu {
                    Picker("Source", selection: $providerRaw) {
                        ForEach(PartsProvider.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(PartsProvider(rawValue: providerRaw)?.title ?? "Automatic", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .glassEffect(.regular.interactive(), in: Capsule())
                .help("Automatic tries TrustedParts, then OEMsecrets, then Octopart")

                Button(action: search) {
                    Text("Search").font(.callout.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3)
                }
                .buttonStyle(.glassProminent)
                .disabled(query.isEmpty || loading)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let secondaryAction {
                Button(secondaryAction.title, action: secondaryAction.action).buttonStyle(.glass)
            }
            if activeSource == .octopart, !resultSource.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text(sourceLine).font(.caption).foregroundStyle(.secondary)
                    if let fallbackNote {
                        Text(fallbackNote).font(.caption2).foregroundStyle(.orange).lineLimit(2).help(fallbackNote)
                    }
                }
            }
            Spacer()
            if let placeAs {
                let detected = ConnectorKind.detect(chosenRaw, libraryCategory: library.library.parts.first { $0.id == selectedLib }?.category)
                Picker("Place as", selection: placeAs) {
                    Text("\(detected.title) (from part data)").tag(ConnectorKind?.none)
                    Divider()
                    ForEach(ConnectorKind.allCases, id: \.self) { Text($0.title).tag(ConnectorKind?.some($0)) }
                }
                .fixedSize()
                .help("What the part is placed as. Worked out from the distributor's category and description; choose another to override.")
            }
            if activeSource == .octopart, let r = selectedResult {
                Button {
                    library.library.upsert(LibraryPart(part: r.partRef, category: category.rawValue, cavityCount: r.positionCount))
                } label: { Label("Add to Library", systemImage: "books.vertical") }
                    .buttonStyle(.glass)
            }
            Button("Cancel", action: cancel)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button { if let p = chosen { pick(p) } } label: {
                Text(confirmTitle).fontWeight(.semibold).padding(.horizontal, 10)
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(chosen == nil)
        }
        .controlSize(.large)
    }

    /// Keeps the best library match selected so Return places it straight away.
    private func preselectLibraryMatch() {
        guard activeSource == .library else { return }
        let parts = library.library.search(query).filter { category == .any || $0.category == category.rawValue }
        if !parts.contains(where: { $0.id == selectedLib }) { selectedLib = parts.first?.id }
    }

    private var chosenRaw: PartRef? {
        switch activeSource {
        case .library: library.library.parts.first { $0.id == selectedLib }?.part
        case .octopart: selectedResult?.partRef
        }
    }

    private var chosen: PartRef? {
        guard var p = chosenRaw else { return nil }
        if category == .connector || placeAs != nil, let n = cavities { p.positionCount = n }
        return p
    }

    /// Cavity count shown for the selected part: the library's, the distributor's, or nil when unknown.
    private var knownCavities: Int? {
        if activeSource == .library, let lp = library.library.parts.first(where: { $0.id == selectedLib }) {
            return lp.cavityCount ?? lp.part.positionCount
        }
        return chosenRaw?.positionCount
    }

    private var libraryTable: some View {
        let parts = library.library.search(query).filter { category == .any || $0.category == category.rawValue }
        return Table(parts, selection: $selectedLib) {
            TableColumn("") { PartPhoto(url: $0.photoURL, size: 38) }.width(44)
            TableColumn("Part") { lp in
                VStack(alignment: .leading, spacing: 1) {
                    Text(lp.part.isGeneric ? (lp.part.description ?? "Generic") : lp.part.mpn)
                        .fontWeight(.semibold)
                        .foregroundStyle(lp.part.isGeneric ? Color.orange : Color.primary)
                    Text(lp.part.isGeneric ? "Generic part" : lp.part.manufacturer).font(.caption).foregroundStyle(.secondary)
                }
            }
            TableColumn("Internal PN") { Text($0.part.internalPN ?? "").foregroundStyle(.secondary) }.width(90)
            TableColumn("Description") { Text($0.part.description ?? "").foregroundStyle(.secondary) }
            TableColumn("Config") { lp in
                if !lp.related.isEmpty { Pill(text: "\(lp.related.count) related", tint: .purple) }
            }.width(84)
        }
        .overlay {
            if parts.isEmpty {
                ContentUnavailableView {
                    Label("No library parts match", systemImage: "books.vertical")
                } description: {
                    Text("Parts you place are remembered here with their configuration.")
                } actions: {
                    Button("Search Online") { source = .octopart; if !query.isEmpty { search() } }
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }

    private var octopartTable: some View {
        Table(results, selection: $selectedOcto) {
            TableColumn("") { PartPhoto(url: enriched[$0.id]?.imageURL ?? $0.imageURL, size: 38) }.width(44)
            TableColumn("Part") { r in
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.mpn).fontWeight(.semibold)
                    Text(r.manufacturer).font(.caption).foregroundStyle(.secondary)
                }
            }
            TableColumn("Description") { Text($0.description ?? "").foregroundStyle(.secondary) }
            TableColumn("Pos.") { r in
                if let n = r.positionCount { Pill(text: "\(n)", tint: Pane.connectors.tint) }
            }.width(46)
            TableColumn("Stock") { r in
                Text(r.totalAvailable.map { $0.formatted(.number.notation(.compactName)) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle((r.totalAvailable ?? 0) > 0 ? Color.green : Color.secondary)
            }.width(60)
            TableColumn("Price") { r in
                Text(r.medianPrice.map { $0.formatted(.currency(code: r.currency ?? "USD").precision(.fractionLength(2...3))) } ?? "—")
                    .monospacedDigit()
            }.width(80)
            TableColumn("Source") { r in SourceBadge(source: r.source) }.width(96)
        }
        .overlay {
            if loading {
                ProgressView("Searching distributors…").padding(20).glassCard()
            } else if results.isEmpty {
                ContentUnavailableView {
                    Label(resultSource == "none" ? "No matches" : "Search distributors",
                          systemImage: resultSource == "none" ? "magnifyingglass" : "globe")
                } description: {
                    Text(resultSource == "none" ? "Distributor search works best with a full or partial part number."
                                                : "Type a part number above and press Return.")
                }
            }
        }
    }

    @ViewBuilder private var detailPanel: some View {
        let octo = activeSource == .octopart ? selectedResult : nil
        let lib = activeSource == .library ? library.library.parts.first { $0.id == selectedLib } : nil
        if let part = octo?.partRef ?? lib?.part {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let photo = lib?.photoURL ?? part.imageURL
                    ZStack(alignment: .bottomTrailing) {
                        PartPhoto(url: photo, size: photo == nil ? 120 : 180)
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            // Real photos sit on white like a product shot; no photo gets a quiet frosted tile.
                            .background(photo == nil ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.white),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        if let o = octo, detailLoading == o.id {
                            ProgressView().controlSize(.small).padding(8).glassEffect(.regular, in: Circle()).padding(8)
                                .help("Checking other sources for the photo and details")
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(part.isGeneric ? "Generic part" : part.mpn)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        Text(part.manufacturer).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        if let o = octo { SourceBadge(source: o.source) }
                        if let p = octo?.partRef { SourceIcons(sources: p.dataSources, all: octo?.sources) }
                        if lib != nil { Pill(text: "In library", tint: .purple) }
                        if let g = part.contactGender { Pill(text: g.capitalized, tint: .blue) }
                        if let o = octo, let extra = enriched[o.id], extra != results.first(where: { $0.id == o.id }) {
                            Pill(text: "Merged sources", tint: .teal).help("Completed with data from other sources")
                        }
                    }
                    if let d = part.description { Text(d).font(.callout).fixedSize(horizontal: false, vertical: true) }

                    if category == .connector || placeAs != nil { cavityCard }

                    if let cfg = lib, !cfg.related.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Adds automatically").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(cfg.related, id: \.self) { r in
                                HStack(spacing: 6) {
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.purple)
                                    Text(r.role.rawValue.capitalized).foregroundStyle(.secondary)
                                    Text(r.part.isGeneric ? (r.part.description ?? "") : r.part.mpn).lineLimit(1)
                                }
                                .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .glassCard(cornerRadius: 14)
                    }

                    if let specs = octo?.specs, !specs.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Specifications").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(specs.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(k).foregroundStyle(.secondary)
                                    Spacer(minLength: 8)
                                    Text(v).multilineTextAlignment(.trailing)
                                }
                                .font(.caption)
                            }
                        }
                        .padding(12)
                        .glassCard(cornerRadius: 14)
                    }

                    HStack(spacing: 8) {
                        if let url = part.datasheetURL {
                            Link(destination: url) { Label("Datasheet", systemImage: "doc.text") }.buttonStyle(.glass)
                        }
                        if let u = octo?.octopartURL {
                            Link(destination: u) { Label("Product", systemImage: "safari") }.buttonStyle(.glass)
                        }
                    }
                }
                .padding(14)
            }
        } else {
            ContentUnavailableView("Select a part", systemImage: "photo.on.rectangle.angled",
                                   description: Text("Its photo, cavity count and specifications appear here."))
        }
    }

    /// Cavity count with where it came from; editable because distributor data is sometimes wrong.
    private var cavityCard: some View {
        let value = cavities ?? knownCavities
        let missing = knownCavities == nil && cavities == nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                IconTile(systemName: "circle.grid.3x3.fill", tint: .orange, size: 26, colored: missing)
                VStack(alignment: .leading, spacing: 0) {
                    Text(value.map(String.init) ?? "?").font(.title2.weight(.semibold)).monospacedDigit()
                    Text("Cavities").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Stepper("Cavities", value: Binding(get: { value ?? 2 }, set: { cavities = $0 }), in: 1...300).labelsHidden()
            }
            if missing {
                Label("Not in the distributor data. Set it from the datasheet before placing.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text(cavities != nil ? "Set by you" : "From \(activeSource == .library ? "the library" : "distributor data")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 14)
    }

    /// The selected online result, completed from other sources when that has been fetched.
    private var selectedResult: PartSummary? {
        guard let id = selectedOcto, let r = results.first(where: { $0.id == id }) else { return nil }
        return enriched[id] ?? r
    }

    /// When the selected result lacks a photo, position count or datasheet, asks the parts sources to look the MPN up
    /// in the other sources (it caches every answer, so each part costs at most one call per source).
    private func fetchDetailIfNeeded() {
        guard activeSource == .octopart, let id = selectedOcto, enriched[id] == nil,
              let r = results.first(where: { $0.id == id }), r.needsDetail, resultSource != "mock" else { return }
        detailLoading = id
        let client = PartsService.client(backendURL)
        Task { @MainActor in
            do {
                let detail = try await client.detail(mpn: r.mpn)
                enriched[id] = detail.part.map { r.filling(from: $0) } ?? r
            } catch {
                // Leave it unenriched so selecting it again retries; say why in the footer.
                fallbackNote = "Couldn't complete \(r.mpn) from other sources: \(error.localizedDescription)"
            }
            if detailLoading == id { detailLoading = nil }
        }
    }

    private func search() {
        guard !query.isEmpty else { return }
        loading = true
        error = nil
        let client = PartsService.client(backendURL)
        Task { @MainActor in
            do {
                let response = try await client.search(query, category: category,
                                                       provider: PartsProvider(rawValue: providerRaw) ?? .auto)
                results = response.results
                resultSource = response.source
                fallbackNote = response.fallbackNote
                enriched = [:]
                selectedOcto = results.first?.id
                fetchDetailIfNeeded()
            } catch {
                self.error = backendURL.isEmpty ? error.localizedDescription : "\(error.localizedDescription). Is the parts service at \(backendURL) running?"
                results = []
            }
            loading = false
        }
    }
}

extension PartSearchView {
    var sourceLine: String {
        switch resultSource {
        case "mock": "Sample data: add distributor API keys in Settings ▸ Parts sources."
        case "none": "No source found this part."
        case "library": "From your parts library: already known, no distributor calls."
        default: "Results from \(PartsProvider.title(of: resultSource))."
        }
    }
}

/// A small tinted capsule.
struct Pill: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

/// Small coloured tag naming the data source of a result.
struct SourceBadge: View {
    let source: String?

    var body: some View {
        Pill(text: source.map(PartsProvider.title(of:)) ?? "Sample", tint: SourceIcons.color(source))
    }
}

/// One small round icon per parts source that supplied this part's data; hover for which field came from where.
struct SourceIcons: View {
    /// Field → source ("imageURL": "digikey").
    let sources: [String: String]?
    /// Every source that knows the part (shown even if it filled no field).
    var all: [String]? = nil

    static let fieldNames = ["imageURL": "Photo", "datasheetURL": "Datasheet", "description": "Description", "medianPrice": "Price"]

    var body: some View {
        let byField = sources ?? [:]
        let names = (all ?? []).filter { $0 != "library" } + byField.values.filter { !(all ?? []).contains($0) }
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !unique.isEmpty {
            HStack(spacing: 3) {
                ForEach(unique, id: \.self) { source in
                    let fields = byField.filter { $0.value == source }.keys.compactMap { Self.fieldNames[$0] }.sorted()
                    Text(Self.initials(source))
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Self.color(source), in: Circle())
                        .help(PartsProvider.title(of: source) + (fields.isEmpty ? "" : ": " + fields.joined(separator: ", ")))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Data from " + unique.map(PartsProvider.title(of:)).joined(separator: ", "))
        }
    }

    static func initials(_ source: String) -> String {
        switch source {
        case "trustedparts": "TP"
        case "mouser": "M"
        case "digikey": "DK"
        case "oemsecrets": "OS"
        case "octopart": "O"
        default: String(source.prefix(2)).uppercased()
        }
    }

    static func color(_ source: String?) -> Color {
        switch source {
        case "trustedparts": .green
        case "mouser": Color(red: 0.0, green: 0.36, blue: 0.67)
        case "digikey": .red
        case "oemsecrets": .teal
        case "octopart": .blue
        case "library": .purple
        default: .secondary
        }
    }
}

/// A part's product photo, loaded through the shared cache; a placeholder while loading or when there is none.
struct PartPhoto: View {
    let url: URL?
    var size: CGFloat = 40
    @State private var image: CGImage?
    @State private var loading = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(4, size * 0.16), style: .continuous)
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .padding(size > 80 ? 0 : 2)
                    .background(Color.white, in: shape)
                    .transition(.opacity)
            } else {
                shape.fill(.quaternary)
                    .overlay {
                        if loading { ProgressView().controlSize(size > 80 ? .regular : .mini) }
                        else { Image(systemName: url == nil ? "shippingbox" : "photo").font(.system(size: size * 0.32)).foregroundStyle(.tertiary) }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = PartImageCache.shared.cached(url)
            if image == nil {
                loading = true
                image = await PartImageCache.shared.image(for: url)
                loading = false
            }
        }
    }
}

extension PartCategory {
    var icon: String {
        switch self {
        case .any: "square.grid.2x2"
        case .connector: "powerplug"
        case .terminal: "pin"
        case .seal: "circle.circle"
        case .cavityPlug: "smallcircle.filled.circle"
        case .accessory: "puzzlepiece"
        case .wire: "line.diagonal"
        case .splice: "arrow.triangle.merge"
        case .heatShrink: "flame"
        case .covering: "cylinder.split.1x2"
        case .tape: "bandage"
        }
    }

    var tint: Color {
        switch self {
        case .any: Pane.bom.tint
        case .connector: Pane.connectors.tint
        case .terminal: Color(red: 0.95, green: 0.70, blue: 0.20)
        case .seal: Pane.labels.tint
        case .cavityPlug: Pane.drawing.tint
        case .accessory: Pane.cables.tint
        case .wire: Pane.wires.tint
        case .splice: Pane.splices.tint
        case .heatShrink: Pane.cutList.tint
        case .covering: Pane.coverings.tint
        case .tape: Pane.tools.tint
        }
    }
}

/// The part search that opens when a component is placed (or a connector's part is changed).
struct PlacePartSheet: View {
    @ObservedObject var doc: HarnessDocument
    @EnvironmentObject var library: LibraryStore
    let placement: HarnessDocument.Placement
    @State private var placeAs: ConnectorKind?

    var body: some View {
        let hasLibraryParts = !library.library.parts.isEmpty
        PartSearchView(category: placement.category,
                       title: placement.title,
                       initialSource: hasLibraryParts ? .library : .octopart,
                       secondaryAction: isNew ? (title: "Place Without Part", action: { doc.completePlacement(placement, part: nil, as: placeAs) }) : nil,
                       confirmTitle: isNew ? "Place" : "Use Part",
                       placeAs: isNew ? $placeAs : nil,
                       pick: { doc.completePlacement(placement, part: $0, as: placeAs) },
                       cancel: { doc.placement = nil })
            .environmentObject(library)
    }

    private var isNew: Bool {
        if case .new = placement.mode { return true }
        return false
    }
}
