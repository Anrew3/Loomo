import CrimpCore
import Foundation

/// The user's parts-source credentials and preferences. Kept in the Keychain by the app (see PartsCredentials);
/// nothing here is ever written to a file.
public struct PartsSettings: Sendable, Equatable {
    public var mouserKey = ""
    public var digikeyClientID = ""
    public var digikeyClientSecret = ""
    public var oemsecretsKey = ""
    public var trustedPartsKey = ""
    public var trustedPartsCompanyID = ""
    public var nexarClientID = ""
    public var nexarClientSecret = ""
    /// Which sources to try first. Sources without credentials are skipped.
    public var order = ["trustedparts", "mouser", "digikey", "oemsecrets", "octopart"]
    public var country = "US"
    public var currency = "USD"
    /// Calls a day each source may use (0 = no limit). Mouser and Digi-Key allow 1,000 a day on free keys.
    public var dailyLimits = ["mouser": 900, "digikey": 900]
    public var monthlyLimits: [String: Int] = [:]

    public init() {}

    /// The sources these settings have credentials for.
    public var configured: [String] {
        var out: [String] = []
        if !trustedPartsKey.isEmpty { out.append("trustedparts") }
        if !mouserKey.isEmpty { out.append("mouser") }
        if !digikeyClientID.isEmpty, !digikeyClientSecret.isEmpty { out.append("digikey") }
        if !oemsecretsKey.isEmpty { out.append("oemsecrets") }
        if !nexarClientID.isEmpty, !nexarClientSecret.isEmpty { out.append("octopart") }
        return out
    }
}

/// Parts search that runs inside Loomo with the user's own API keys: no server, no Python, nothing to install.
///
/// Searches go through a chain of sources (TrustedParts → Mouser → Digi-Key → OEMsecrets → Octopart by default),
/// moving on when a source isn't set up, is over its call budget, is pausing after a limit error, fails, or finds
/// nothing. Everything any source says about a part is merged into a local parts database, one record per part
/// number, noting which source supplied each field. Searches answer from it when it already knows the part, and
/// filling in a part asks the next source only for what's still missing (photo, datasheet, description).
/// With no sources set up, a small sample catalog answers, so the app still works.
public actor PartsEngine {
    public static let shared = PartsEngine()

    static let cacheTTL: TimeInterval = 7 * 24 * 3600
    static let askAgainAfter: TimeInterval = 30 * 24 * 3600
    static let cooldown: TimeInterval = 3600
    static let categoryHints = ["any": "", "connector": "connector housing", "terminal": "crimp contact terminal", "seal": "wire seal",
                                "cavity_plug": "cavity plug", "accessory": "wedgelock backshell", "wire": "automotive wire",
                                "splice": "splice", "heat_shrink": "heat shrink tubing",
                                "covering": "convoluted tubing braided sleeve", "tape": "harness tape"]
    /// Fields filled from whichever source has them, and the ones a part needs before Loomo stops asking.
    static let fillFields = ["imageURL", "datasheetURL", "description", "category", "medianPrice", "currency", "totalAvailable", "octopartURL"]
    static let wanted = ["imageURL", "datasheetURL", "description"]

    private var settings = PartsSettings()
    private var sources: [String: any PartsSource] = [:]
    private var cooldownUntil: [String: Date] = [:]
    private var store: PartsStore
    private let storeURL: URL?
    /// Photo checks; tests swap in a stub.
    var imageCheck: @Sendable (URL) async -> Bool = PartsEngine.servesImage

    /// - Parameter storeURL: where the parts database lives; nil keeps it in memory (tests).
    public init(storeURL: URL? = SharedStorage.dataDirectory.appendingPathComponent("PartsDatabase.json")) {
        self.storeURL = storeURL
        self.store = storeURL.flatMap { try? JSONDecoder().decode(PartsStore.self, from: Data(contentsOf: $0)) } ?? PartsStore()
    }

    /// Replaces the credentials and preferences; sources whose keys changed start fresh.
    public func configure(_ s: PartsSettings) {
        settings = s
        var built: [String: any PartsSource] = [:]
        if !s.trustedPartsKey.isEmpty {
            built["trustedparts"] = TrustedPartsSource(apiKey: s.trustedPartsKey, companyID: s.trustedPartsCompanyID, country: s.country, currency: s.currency)
        }
        if !s.mouserKey.isEmpty { built["mouser"] = MouserSource(apiKey: s.mouserKey) }
        if !s.digikeyClientID.isEmpty, !s.digikeyClientSecret.isEmpty {
            built["digikey"] = DigiKeySource(clientID: s.digikeyClientID, clientSecret: s.digikeyClientSecret, country: s.country, currency: s.currency)
        }
        if !s.oemsecretsKey.isEmpty { built["oemsecrets"] = OEMsecretsSource(apiKey: s.oemsecretsKey, country: s.country, currency: s.currency) }
        if !s.nexarClientID.isEmpty, !s.nexarClientSecret.isEmpty {
            built["octopart"] = NexarSource(clientID: s.nexarClientID, clientSecret: s.nexarClientSecret)
        }
        sources = built
        cooldownUntil = [:]
    }

    /// For tests: sources that don't call the network, photo checks, and budgets.
    func use(_ list: [any PartsSource]) {
        sources = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
        settings.order = list.map(\.name)
        settings.dailyLimits = [:]
    }
    func setImageCheck(_ check: @escaping @Sendable (URL) async -> Bool) { imageCheck = check }
    func setDailyLimit(_ name: String, _ n: Int) { settings.dailyLimits[name] = n }

    public var configured: [String] { ordered().map(\.name) }

    private func ordered() -> [any PartsSource] { settings.order.compactMap { sources[$0] } }

    // MARK: Budgets

    private static func day(_ d: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    func calls(_ name: String, month: Bool = false) -> Int {
        let prefix = month ? String(Self.day().prefix(7)) : Self.day()
        return (store.usage[name] ?? [:]).filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
    }

    private func recordCall(_ name: String) { store.usage[name, default: [:]][Self.day(), default: 0] += 1 }

    func unavailableReason(_ name: String) -> String? {
        if let until = cooldownUntil[name], Date() < until {
            return "paused after a limit error until \(until.formatted(date: .omitted, time: .shortened))"
        }
        if let limit = settings.dailyLimits[name], limit > 0, calls(name) >= limit { return "daily budget of \(limit) calls used" }
        if let limit = settings.monthlyLimits[name], limit > 0, calls(name, month: true) >= limit { return "monthly budget of \(limit) calls used" }
        return nil
    }

    // MARK: One source

    private func search(_ source: any PartsSource, _ q: String, category: String, limit: Int, fresh: Bool = false) async throws -> [PartSummary] {
        let key = "\(source.name)|search|\(q.lowercased())|\(category)|\(limit)"
        if !fresh, let hit = store.searches[key], Date().timeIntervalSince(hit.at) < Self.cacheTTL { return hit.value }
        recordCall(source.name)
        let query = source.name == "octopart" && !Self.looksLikeMPN(q) ? "\(q) \(Self.categoryHints[category] ?? "")".trimmingCharacters(in: .whitespaces) : q
        let raw: [SourcePart]
        do {
            raw = try await source.search(query, limit: limit)
        } catch let e as ProviderLimitError {
            cooldownUntil[source.name] = Date().addingTimeInterval(Self.cooldown)
            save()
            throw e
        }
        var results: [PartSummary] = []
        for r in raw { results.append(await withCheckedPhoto(r)) }
        store.searches[key] = Timed(results)
        save()
        return results
    }

    /// Some distributor photo links are pages or block hotlinking: keep the first candidate that serves an image.
    private func withCheckedPhoto(_ r: SourcePart) async -> PartSummary {
        var part = r.part
        guard let candidates = r.images else { return part }
        part.imageURL = nil
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            // Mouser's image server answers non-browser clients with a bot check; its photos are real and the app
            // loads them through a browser view.
            if candidate.range(of: #"^https://([a-z]+\.)?mouser\.[a-z.]+/images/"#, options: [.regularExpression, .caseInsensitive]) != nil {
                part.imageURL = url
                break
            }
            let verdict: Bool
            if let known = store.images[candidate], Date().timeIntervalSince(known.at) < Self.cacheTTL {
                verdict = known.value
            } else {
                verdict = await imageCheck(url)
                store.images[candidate] = Timed(verdict)
            }
            if verdict {
                part.imageURL = url
                break
            }
        }
        return part
    }

    static let servesImage: @Sendable (URL) async -> Bool = { url in
        var r = URLRequest(url: url, timeoutInterval: 5)
        r.setValue("Mozilla/5.0 Loomo", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: r), let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200 && (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("image/") && data.count > 1500
    }

    static func looksLikeMPN(_ q: String) -> Bool {
        !q.trimmingCharacters(in: .whitespaces).contains(" ") && q.contains { $0.isNumber }
    }

    // MARK: Parts database

    /// Fills gaps in `target` from `other` (the same part from another source). Returns the fields it filled.
    @discardableResult
    static func merge(_ target: inout PartSummary, _ other: PartSummary) -> [String] {
        var filled: [String] = []
        var credit = target.fieldSources ?? [:]
        func take<T>(_ field: String, _ mine: WritableKeyPath<PartSummary, T?>) {
            let theirs = other[keyPath: mine]
            guard Self.isEmpty(target[keyPath: mine]), !Self.isEmpty(theirs) else { return }
            target[keyPath: mine] = theirs
            credit[field] = other.fieldSources?[field] ?? other.source ?? ""
            filled.append(field)
        }
        take("imageURL", \.imageURL)
        take("datasheetURL", \.datasheetURL)
        take("description", \.description)
        take("category", \.category)
        take("medianPrice", \.medianPrice)
        take("currency", \.currency)
        take("totalAvailable", \.totalAvailable)
        take("octopartURL", \.octopartURL)
        target.fieldSources = credit
        let aliases = ["number of positions": "positions", "positions": "positions", "number of rows": "rows", "rows": "rows",
                       "pitch": "pitch", "pitch (mm)": "pitch", "contact gender": "gender", "gender": "gender"]
        let have = Set(target.specs.keys.map { aliases[$0.lowercased()] ?? $0.lowercased() })
        for (k, v) in other.specs.sorted(by: { $0.key < $1.key }) where !have.contains(aliases[k.lowercased()] ?? k.lowercased()) && k != "Offers" && k != "Distributors" {
            target.specs[k] = v
            filled.append("specs")
        }
        var names = target.sources ?? []
        for name in other.sources ?? [other.source].compactMap({ $0 }) where !name.isEmpty && !names.contains(name) { names.append(name) }
        target.sources = names
        return filled
    }

    private static func isEmpty<T>(_ v: T?) -> Bool {
        guard let v else { return true }
        return (v as? String)?.isEmpty ?? false
    }

    /// A source's result with its own fields credited to it.
    static func stamped(_ r: PartSummary) -> PartSummary {
        var r = r
        var credit = r.fieldSources ?? [:]
        let has: [String: Bool] = ["imageURL": r.imageURL != nil, "datasheetURL": r.datasheetURL != nil, "description": !(r.description ?? "").isEmpty,
                                   "category": !(r.category ?? "").isEmpty, "medianPrice": r.medianPrice != nil, "currency": !(r.currency ?? "").isEmpty,
                                   "totalAvailable": r.totalAvailable != nil, "octopartURL": r.octopartURL != nil]
        for field in fillFields where has[field] == true && credit[field] == nil { credit[field] = r.source ?? "" }
        r.fieldSources = credit
        var names = r.sources ?? []
        if let s = r.source, !names.contains(s) { names.insert(s, at: 0) }
        r.sources = names
        return r
    }

    static func missing(_ r: PartSummary?) -> [String] {
        guard let r else { return wanted }
        return [r.imageURL == nil ? "imageURL" : nil, r.datasheetURL == nil ? "datasheetURL" : nil,
                (r.description ?? "").isEmpty ? "description" : nil].compactMap { $0 }
    }

    private func known(_ mpn: String) -> PartSummary? { store.parts[normMPN(mpn)]?.value }

    /// Merges a source's answer into the part's record and returns the record.
    @discardableResult
    private func learn(_ r: PartSummary) -> PartSummary {
        var record: PartSummary
        if var k = known(r.mpn) {
            Self.merge(&k, Self.stamped(r))
            record = k
        } else {
            record = Self.stamped(r)
            record.source = "library"
        }
        store.parts[normMPN(r.mpn)] = Timed(record)
        return record
    }

    /// Parts the database already knows whose number, maker or description contain every word of the query.
    private func searchKnown(_ q: String, limit: Int, excluding: Set<String> = []) -> [PartSummary] {
        let words = q.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty, limit > 0 else { return [] }
        var out: [PartSummary] = []
        for entry in store.parts.values.sorted(by: { $0.at > $1.at }).prefix(5000) {
            let r = entry.value
            let text = "\(r.mpn) \(normMPN(r.mpn)) \(r.manufacturer) \(r.description ?? "")".lowercased()
            if !excluding.contains(normMPN(r.mpn)), words.allSatisfy({ text.contains($0) || text.contains(normMPN($0)) }) {
                out.append(r)
                if out.count >= limit { break }
            }
        }
        return out
    }

    private func markAsked(_ mpn: String, _ source: String, found: Bool) {
        store.asked[normMPN(mpn), default: [:]][source] = Timed(found)
    }

    /// Stores what a source returned and gives back each result with gaps filled from everything known about that
    /// part. The answering source's own wording and values win; the database only fills gaps.
    private func remember(_ results: [PartSummary], from source: String) -> [PartSummary] {
        results.map { r in
            let record = learn(r)
            var mine = Self.stamped(r)
            Self.merge(&mine, record)
            if !normMPN(r.mpn).isEmpty { markAsked(r.mpn, source, found: true) }
            return mine
        }
    }

    /// Asks each source in turn about one part number until its photo, datasheet and description are all known.
    /// Sources already asked (found or not) within the last 30 days are skipped.
    private func fill(_ mpn: String, attempts: inout [ProviderAttempt], skipping: Set<String> = []) async -> PartSummary? {
        let key = normMPN(mpn)
        var record = known(mpn)
        let seen = store.asked[key] ?? [:]
        for source in ordered() {
            if Self.missing(record).isEmpty { break }
            if skipping.contains(source.name) { continue }
            if let s = seen[source.name], Date().timeIntervalSince(s.at) < Self.askAgainAfter { continue }
            if let reason = unavailableReason(source.name) {
                attempts.append(ProviderAttempt(provider: source.name, ok: false, skipped: true, error: reason))
                continue
            }
            let results: [PartSummary]
            do {
                results = try await search(source, mpn, category: "any", limit: 10)
            } catch {
                attempts.append(ProviderAttempt(provider: source.name, ok: false, error: String(error.localizedDescription.prefix(200))))
                continue
            }
            let exact = results.first { normMPN($0.mpn) == key }
            attempts.append(ProviderAttempt(provider: source.name, ok: true, count: exact == nil ? 0 : 1))
            markAsked(mpn, source.name, found: exact != nil)
            if let exact { record = learn(exact) }
        }
        save()
        return record
    }

    // MARK: Public API (the same answers the old backend gave)

    public func search(_ query: String, category: PartCategory = .any, limit: Int = 20, provider: PartsProvider = .auto) async throws -> SearchResponse {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(1, min(limit, 50))
        let chain = provider == .auto ? ordered() : ordered().filter { $0.name == provider.rawValue }
        if provider != .auto, chain.isEmpty { throw PartsError.notSetUp(provider.title) }
        if sources.isEmpty { return SearchResponse(source: "mock", results: Self.sample(q, category: category.rawValue, limit: limit)) }

        // The database answers on its own when it already has everything about the part number asked for.
        if provider == .auto, Self.looksLikeMPN(q), let k = known(q), Self.missing(k).isEmpty {
            let extra = searchKnown(q, limit: limit - 1, excluding: [normMPN(k.mpn)])
            return SearchResponse(source: "library", results: [k] + extra,
                                  attempts: [ProviderAttempt(provider: "library", ok: true, count: 1 + extra.count)])
        }

        var attempts: [ProviderAttempt] = []
        for source in chain {
            if let reason = unavailableReason(source.name) {
                attempts.append(ProviderAttempt(provider: source.name, ok: false, skipped: true, error: reason))
                continue
            }
            var searchFor = q
            var words: [String] = []
            if !source.keywordSearch, !Self.looksLikeMPN(q) {
                // "tesa 51036" or "techflex PTN0.25": search the part-number word, keep results matching the rest.
                let tokens = q.split(separator: " ").map(String.init)
                guard let mpn = tokens.first(where: { Self.looksLikeMPN($0) && $0.count >= 4 }) else {
                    attempts.append(ProviderAttempt(provider: source.name, ok: false, skipped: true, error: "part-number search only"))
                    continue
                }
                searchFor = mpn
                words = tokens.filter { $0 != mpn }.map { $0.lowercased() }
            }
            var results: [PartSummary]
            do {
                results = try await search(source, searchFor, category: category.rawValue, limit: limit)
                if !words.isEmpty {
                    results = results.filter { r in words.allSatisfy { "\(r.manufacturer) \(r.description ?? "") \(r.mpn)".lowercased().contains($0) } }
                }
            } catch {
                attempts.append(ProviderAttempt(provider: source.name, ok: false, error: String(error.localizedDescription.prefix(200))))
                continue
            }
            attempts.append(ProviderAttempt(provider: source.name, ok: true, count: results.count))
            guard !results.isEmpty else { continue }
            results = remember(results, from: source.name)
            // A part number asked for exactly: go down the line for whatever this source lacked.
            if provider == .auto, let i = results.firstIndex(where: { normMPN($0.mpn) == normMPN(q) }), !Self.missing(results[i]).isEmpty,
               let filled = await fill(results[i].mpn, attempts: &attempts, skipping: [source.name]) {
                Self.merge(&results[i], filled)
            }
            // Parts the database knows that this source didn't list.
            results += searchKnown(q, limit: max(0, limit - results.count), excluding: Set(results.map { normMPN($0.mpn) }))
            save()
            return SearchResponse(source: source.name, results: results, attempts: attempts)
        }
        if provider != .auto, let last = attempts.last, !last.ok { throw PartsError.server(502, last.error ?? "failed") }
        let local = searchKnown(q, limit: limit)
        save()
        if !local.isEmpty {
            attempts.append(ProviderAttempt(provider: "library", ok: true, count: local.count))
            return SearchResponse(source: "library", results: local, attempts: attempts)
        }
        return SearchResponse(source: "none", results: [], attempts: attempts)
    }

    /// Everything known about one part, merged across sources. Each source is asked at most once per part number
    /// per 30 days (and only within its budget); photos and specs from any source fill the gaps.
    public func detail(mpn: String) async -> DetailResponse {
        var attempts: [ProviderAttempt] = []
        let record = await fill(mpn, attempts: &attempts)
        return DetailResponse(part: record, sources: record?.sources ?? [], attempts: attempts)
    }

    /// Current price and stock for a BOM. TrustedParts answers 50 part numbers per call, so it goes first when set
    /// up; otherwise one OEMsecrets call per part number (cached).
    public func offers(for mpns: [String]) async -> OffersResponse {
        var seen = Set<String>()
        let list = mpns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 && seen.insert($0).inserted }
        var out: [String: PartSummary] = [:]
        var errors: [String] = []
        if let tp = sources["trustedparts"] as? TrustedPartsSource, unavailableReason(tp.name) == nil {
            for start in stride(from: 0, to: list.count, by: 50) {
                do {
                    recordCall(tp.name)
                    for (k, v) in try await tp.offers(Array(list[start..<min(start + 50, list.count)])) { out[k] = await withCheckedPhoto(v) }
                } catch {
                    errors.append(String(error.localizedDescription.prefix(200)))
                    break
                }
            }
        }
        if let oem = sources["oemsecrets"] as? OEMsecretsSource {
            for m in list where out[m] == nil {
                if unavailableReason(oem.name) != nil { break }
                let key = "oemsecrets|offer|\(m.lowercased())"
                if let hit = store.offers[key], Date().timeIntervalSince(hit.at) < Self.cacheTTL {
                    if let v = hit.value { out[m] = v }
                    continue
                }
                do {
                    recordCall(oem.name)
                    let found = try await oem.offer(m)
                    let part: PartSummary? = if let found { await withCheckedPhoto(found) } else { nil }
                    store.offers[key] = Timed(part)
                    if let part { out[m] = part }
                } catch let e as ProviderLimitError {
                    cooldownUntil[oem.name] = Date().addingTimeInterval(Self.cooldown)
                    errors.append(e.message)
                    break
                } catch {
                    errors.append(String(error.localizedDescription.prefix(200)))
                }
            }
        }
        save()
        return OffersResponse(offers: out, missing: list.filter { out[$0] == nil }, errors: errors)
    }

    public func usage() -> [String: ProviderUsage] {
        Dictionary(uniqueKeysWithValues: ordered().map { s in
            (s.name, ProviderUsage(callsToday: calls(s.name), callsThisMonth: calls(s.name, month: true),
                                   dailyLimit: settings.dailyLimits[s.name].flatMap { $0 > 0 ? $0 : nil },
                                   monthlyLimit: settings.monthlyLimits[s.name].flatMap { $0 > 0 ? $0 : nil },
                                   unavailable: unavailableReason(s.name)))
        })
    }

    /// Checks one source's credentials with a single real search (not cached). Returns what it found.
    public func test(_ provider: PartsProvider) async throws -> String {
        guard let source = sources[provider.rawValue] else { throw PartsError.notSetUp(provider.title) }
        let results = try await search(source, "DT06-2S", category: "any", limit: 3, fresh: true)
        return results.isEmpty ? "Connected. The test search found no parts, which can be normal for this source."
            : "Connected. Found \(results[0].mpn) from \(results[0].manufacturer.isEmpty ? "a distributor" : results[0].manufacturer)."
    }

    /// Forgets cached answers and learned parts (the user's parts library is separate and untouched).
    public func clearDatabase() {
        store = PartsStore()
        save()
    }

    // MARK: Sample catalog and storage

    static let sampleParts: [PartSummary] = (try? JSONDecoder().decode([PartSummary].self, from: Data(SampleParts.json.utf8))) ?? []

    static func sample(_ q: String, category: String, limit: Int) -> [PartSummary] {
        let words = q.lowercased().split(separator: " ")
        return Array(sampleParts.filter { p in
            (category == "any" || category == p.category)
                && words.allSatisfy { "\(p.mpn) \(p.manufacturer) \(p.description ?? "")".lowercased().contains($0) }
        }.prefix(limit))
    }

    private func save() {
        guard let storeURL else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(store).write(to: storeURL, options: .atomic)
    }
}

struct Timed<T: Codable>: Codable {
    var at: Date
    var value: T
    init(_ value: T, at: Date = Date()) {
        self.value = value
        self.at = at
    }
}

/// Everything the engine remembers between launches: the learned parts database, cached answers and call counts.
struct PartsStore: Codable {
    var parts: [String: Timed<PartSummary>] = [:]
    var searches: [String: Timed<[PartSummary]>] = [:]
    var offers: [String: Timed<PartSummary?>] = [:]
    var images: [String: Timed<Bool>] = [:]
    var asked: [String: [String: Timed<Bool>]] = [:]
    /// source → "YYYY-MM-DD" → calls
    var usage: [String: [String: Int]] = [:]
}
