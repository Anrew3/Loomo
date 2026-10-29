import CrimpCore
import PartsClient
import SwiftUI
import UniformTypeIdentifiers

/// The private/team part library: parts with internal PNs, approved alternates, terminal data
/// and design configurations (the related parts added automatically when a housing is used).
struct LibraryWindow: View {
    @EnvironmentObject var library: LibraryStore
    @State private var query = ""
    @State private var category: PartCategory = .any
    @State private var selection: LibraryPart.ID?
    @State private var showDuplicates = false

    var body: some View {
        let parts = library.library.search(query).filter { category == .any || $0.category == category.rawValue }
        NavigationSplitView {
            VStack(spacing: 0) {
                Table(parts, selection: $selection) {
                    TableColumn("") { PartPhoto(url: $0.photoURL, size: 28) }.width(34)
                    TableColumn("MPN") { Text($0.part.isGeneric ? "Generic: \($0.part.description ?? "")" : $0.part.mpn) }
                    TableColumn("Internal PN") { Text($0.part.internalPN ?? "") }.width(90)
                    TableColumn("Category") { Text(PartCategory(rawValue: $0.category)?.title ?? $0.category) }.width(110)
                }
                Divider()
                HStack {
                    Text("\(library.library.parts.count) parts").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Duplicates (\(library.library.duplicates().count))") { showDuplicates = true }
                        .disabled(library.library.duplicates().isEmpty)
                    Button { addGeneric() } label: { Image(systemName: "plus") }.help("New generic part")
                    Button { remove() } label: { Image(systemName: "minus") }.disabled(selection == nil)
                }
                .padding(6)
            }
            .navigationSplitViewColumnWidth(min: 380, ideal: 440)
            .searchable(text: $query, placement: .sidebar, prompt: "MPN, internal PN, alternate…")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let why = library.saveError {
                    Label("The parts library couldn't be saved: \(why). Changes stay in memory until a save succeeds.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.white)
                        .padding(10).frame(maxWidth: .infinity)
                        .background(.red)
                }
            }
            .toolbar {
                TeamLibraryBadge()
                Picker("Category", selection: $category) { ForEach(PartCategory.allCases) { Text($0.title).tag($0) } }
                Button("Import…") { importLibrary() }
                Button("Export…") { exportLibrary() }
            }
        } detail: {
            if let id = selection, let i = library.library.parts.firstIndex(where: { $0.id == id }) {
                LibraryPartEditor(entry: Binding(get: { library.library.parts[safe: i] ?? library.library.parts[0] },
                                                 set: { library.library.parts[i] = $0 }))
                    .id(id)
            } else {
                ContentUnavailableView("Select a part", systemImage: "shippingbox",
                                       description: Text("Add parts from any part field's search sheet, or create generic parts here."))
            }
        }
        .sheet(isPresented: $showDuplicates) {
            VStack(alignment: .leading) {
                Text("Parts that share an MPN").font(.headline)
                List(library.library.duplicates().filter { !$0.isEmpty }, id: \.[0].id) { group in
                    Text(group.map { "\($0.part.mpn) (\($0.part.manufacturer))" }.joined(separator: "  ·  "))
                }
                HStack { Spacer(); Button("Done") { showDuplicates = false }.keyboardShortcut(.defaultAction) }
            }
            .padding().frame(width: 520, height: 360)
        }
    }

    private func addGeneric() {
        var p = PartRef.generic("New generic part")
        p.description = "New generic part \(library.library.parts.count + 1)"
        let entry = LibraryPart(part: p, category: category == .any ? "terminal" : category.rawValue)
        library.library.upsert(entry)
        selection = entry.id
    }

    private func remove() {
        library.library.parts.removeAll { $0.id == selection }
        selection = nil
    }

    private func exportLibrary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Loomo Library.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? library.library.save(to: url)
    }

    private func importLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let other = PartLibrary.load(from: url)
        for p in other.parts { library.library.upsert(p) }
    }
}

private struct LibraryPartEditor: View {
    @Binding var entry: LibraryPart
    @State private var alternatesText = ""
    @State private var dropTargeted = false
    @State private var photoError: String?

    var body: some View {
        Form {
            Section("Photo") { photoSection }
            Section("Part") {
                Toggle("Generic placeholder", isOn: $entry.part.isGeneric)
                TextField("MPN", text: $entry.part.mpn)
                TextField("Manufacturer", text: $entry.part.manufacturer)
                TextField("Description", text: $entry.part.description.orEmpty)
                TextField("Internal part number", text: $entry.part.internalPN.orEmpty)
                Picker("Category", selection: $entry.category) {
                    ForEach(PartCategory.allCases.filter { $0 != .any }) { Text($0.title).tag($0.rawValue) }
                }
                TextField("Approved alternates (comma separated)", text: $alternatesText)
                    .onAppear { alternatesText = entry.part.alternates.joined(separator: ", ") }
                    .onSubmit { entry.part.alternates = alternatesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                NumberField("Unit price", value: $entry.part.unitPrice.orZero)
            }
            if entry.category == "connector" {
                Section("Housing") {
                    Stepper("Cavities: \(entry.cavityCount ?? 0)", value: Binding(get: { entry.cavityCount ?? 0 }, set: { entry.cavityCount = $0 == 0 ? nil : $0 }), in: 0...300)
                    Toggle("Individually sealed", isOn: Binding(get: { entry.sealed ?? false }, set: { entry.sealed = $0 }))
                }
            }
            if ["terminal", "splice", "seal"].contains(entry.category) {
                Section("Terminal data (used for lengths, tools and rule checks)") {
                    NumberField("Strip length (mm)", value: $entry.part.stripLengthMM.orZero)
                    TextField("Crimp tool", text: $entry.part.crimpTool.orEmpty)
                    NumberField("Min wire (mm²)", value: $entry.part.minWireMM2.orZero)
                    NumberField("Max wire (mm²)", value: $entry.part.maxWireMM2.orZero)
                    NumberField("Min insulation Ø (mm)", value: $entry.part.minInsulationODMM.orZero)
                    NumberField("Max insulation Ø (mm)", value: $entry.part.maxInsulationODMM.orZero)
                }
            }
            Section("Design configuration (added automatically when this part is used)") {
                ForEach(entry.related.indices, id: \.self) { i in
                    HStack {
                        Picker("", selection: $entry.related[i].role) {
                            ForEach(RelatedPart.Role.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 110)
                        Text(entry.related[i].part.isGeneric ? (entry.related[i].part.description ?? "") : entry.related[i].part.mpn)
                        Spacer()
                        Stepper("×\(entry.related[i].quantity)", value: $entry.related[i].quantity, in: 1...50)
                        Button { entry.related.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                PartField(title: "Add related part", part: Binding(get: { nil }, set: { p in
                    if let p { entry.related.append(RelatedPart(role: .terminal, part: p)) }
                }), category: .any)
            }
            Section("Notes") { TextField("Notes", text: $entry.notes, axis: .vertical) }
        }
        .formStyle(.grouped)
    }

    /// The part's photo. A custom photo is copied into the library and replaces the distributor's
    /// photo on drawings, PDFs, the pinout editor and the wire sheet for every design using this part.
    private var photoSection: some View {
        HStack(alignment: .top, spacing: 14) {
            PartPhoto(url: entry.photoURL, size: 120)
                .frame(width: 120, height: 120)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dropTargeted ? Color.accentColor : .clear, lineWidth: 2))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false }) else { return false }
                    setPhoto(url)
                    return true
                } isTargeted: { dropTargeted = $0 }
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.customPhotoURL != nil ? "Your photo" : entry.part.imageURL != nil ? "Distributor photo" : "No photo")
                    .font(.headline)
                Text("Choose an image or drop one here. It is saved in your library and used everywhere this part appears.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Choose Photo…") { choosePhoto() }
                    if entry.customPhotoURL != nil {
                        Button(entry.part.imageURL != nil ? "Use Distributor Photo" : "Remove Photo") {
                            LibraryStore.shared.clearCustomPhoto(for: entry.id)
                        }
                    }
                }
                if let photoError { Text(photoError).font(.caption).foregroundStyle(.red) }
            }
        }
        .padding(.vertical, 4)
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a photo for \(entry.part.mpn)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setPhoto(url)
    }

    private func setPhoto(_ url: URL) {
        do {
            try LibraryStore.shared.setCustomPhoto(from: url, for: entry.id)
            photoError = nil
        } catch {
            photoError = "Couldn't use that image: \(error.localizedDescription)"
        }
    }
}

/// Team-library sync status in the Library window's toolbar; click to sync now.
private struct TeamLibraryBadge: View {
    @ObservedObject var team = TeamLibrary.shared

    var body: some View {
        if team.enabled {
            Button { Task { await team.sync() } } label: {
                Label("Team Library", systemImage: icon)
            }
            .help("Team library: \(team.status.text) — click to sync now")
        }
    }

    private var icon: String {
        switch team.status {
        case .syncing, .checking: "arrow.triangle.2.circlepath.icloud"
        case .failed, .signedOut: "exclamationmark.icloud"
        case .synced: team.usingSharedLibrary ? "person.2.icloud" : "checkmark.icloud"
        default: "icloud"
        }
    }
}
