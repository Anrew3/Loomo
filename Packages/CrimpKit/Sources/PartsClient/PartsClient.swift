import Foundation
import CrimpCore

/// Part categories for searches; each adds hint words to Octopart keyword searches.
public enum PartCategory: String, CaseIterable, Sendable, Identifiable {
    case any, connector, terminal, seal, cavityPlug = "cavity_plug", accessory, wire, splice, heatShrink = "heat_shrink", covering, tape
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .any: "Any"
        case .connector: "Connector housing"
        case .terminal: "Terminal / contact"
        case .seal: "Wire seal"
        case .cavityPlug: "Cavity plug"
        case .accessory: "Accessory"
        case .wire: "Wire"
        case .splice: "Splice"
        case .heatShrink: "Heat shrink"
        case .covering: "Tube / sleeve"
        case .tape: "Tape"
        }
    }
}

/// A part found by a parts search (PartsEngine).
public struct PartSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var mpn: String
    public var manufacturer: String
    public var description: String?
    public var category: String?
    public var datasheetURL: URL?
    public var imageURL: URL?
    public var octopartURL: URL?
    public var medianPrice: Double?
    public var currency: String?
    public var totalAvailable: Int?
    public var specs: [String: String]
    /// "trustedparts", "mouser", "digikey", "oemsecrets", "octopart", "library" or nil (sample data).
    public var source: String?
    public var distributors: Int?
    /// Which provider supplied each field ("imageURL": "digikey"), from the parts database.
    public var fieldSources: [String: String]?
    /// Every provider that knows this part.
    public var sources: [String]?

    /// Fills what this result lacks (photo, datasheet, description, specs) from another source's result
    /// for the same part. What this result already has wins.
    public func filling(from other: PartSummary) -> PartSummary {
        var out = self
        out.description = description ?? other.description
        out.datasheetURL = datasheetURL ?? other.datasheetURL
        out.imageURL = imageURL ?? other.imageURL
        out.octopartURL = octopartURL ?? other.octopartURL
        out.medianPrice = medianPrice ?? other.medianPrice
        out.currency = currency ?? other.currency
        out.totalAvailable = totalAvailable ?? other.totalAvailable
        out.distributors = distributors ?? other.distributors
        out.specs = other.specs.merging(specs) { _, mine in mine }
        var credit = fieldSources ?? [:]
        for (field, mine, theirs) in [("description", description == nil, other.description != nil),
                                      ("datasheetURL", datasheetURL == nil, other.datasheetURL != nil),
                                      ("imageURL", imageURL == nil, other.imageURL != nil),
                                      ("medianPrice", medianPrice == nil, other.medianPrice != nil)] where mine && theirs {
            credit[field] = other.fieldSources?[field] ?? other.source
        }
        out.fieldSources = credit.isEmpty ? nil : credit
        let all = (sources ?? [source].compactMap { $0 }) + (other.sources ?? [other.source].compactMap { $0 })
        out.sources = all.reduce(into: [String]()) { if !$0.contains($1) && $1 != "library" { $0.append($1) } }
        return out
    }

    /// True when a connector result is missing what placement needs most: a photo or the position count.
    public var needsDetail: Bool { imageURL == nil || positionCount == nil || datasheetURL == nil }

    public var partRef: PartRef {
        var p = PartRef(mpn: mpn, manufacturer: manufacturer, description: description,
                        octopartID: id, datasheetURL: datasheetURL, unitPrice: medianPrice)
        p.imageURL = imageURL
        p.positionCount = positionCount
        var credit = fieldSources ?? [:]
        if let source, source != "library" {
            for (field, has) in [("description", description != nil), ("datasheetURL", datasheetURL != nil),
                                 ("imageURL", imageURL != nil), ("medianPrice", medianPrice != nil)] where has && credit[field] == nil {
                credit[field] = source
            }
        }
        p.dataSources = credit.isEmpty ? nil : credit
        p.category = category
        p.contactGender = contactGender
        p.rowCount = spec("rows").flatMap { Int($0.prefix { $0.isNumber }) }
        p.pitchMM = spec("pitch").flatMap { Double($0.prefix { $0.isNumber || $0 == "." }) }
        // Sleeving and heat shrink: the bundle range they fit, from distributor specs such as
        // "Inside Diameter = 6.4 mm (0.252 in)" and "Recovered Diameter = 3.2 mm".
        p.maxInsulationODMM = millimetres(["expanded", "inside diameter", "inner diameter", "max diameter", "maximum diameter"])
        p.minInsulationODMM = millimetres(["recovered", "min diameter", "minimum diameter"])
        return p
    }

    /// The first spec whose name contains one of `keys`, read as millimetres ("6.4 mm (0.252 in)", "0.25 in").
    func millimetres(_ keys: [String]) -> Double? {
        for key in keys {
            guard let v = spec(key) else { continue }
            let text = v.lowercased()
            if let r = text.range(of: #"([0-9]*\.?[0-9]+)\s*mm"#, options: .regularExpression) {
                return Double(text[r].filter { $0.isNumber || $0 == "." })
            }
            if let r = text.range(of: #"([0-9]*\.?[0-9]+)\s*(in|")"#, options: .regularExpression),
               let inches = Double(text[r].filter { $0.isNumber || $0 == "." }) {
                return inches * 25.4
            }
        }
        return nil
    }

    /// Cavity/position count from specs such as "Number of Positions", "positions", "numberofcontacts" or "ways".
    public var positionCount: Int? {
        for (k, v) in specs {
            let key = k.lowercased()
            guard key.contains("position") || key.contains("numberofcontacts") || key.contains("number of contacts")
                || key == "ways" || key.contains("cavities") else { continue }
            if let n = Int(v.prefix { $0.isNumber }), n > 0 { return n }
        }
        // "DT plug, 4-way" style descriptions.
        if let d = description?.lowercased(), let r = d.range(of: #"(\d+)[- ]?(way|pos|position|pin|cavity)"#, options: .regularExpression) {
            return Int(d[r].prefix { $0.isNumber })
        }
        return nil
    }

    private func spec(_ key: String) -> String? {
        specs.first { $0.key.lowercased().contains(key) }?.value
    }

    public var contactGender: String? {
        for (k, v) in specs where k.lowercased().contains("gender") { return v }
        return nil
    }
}

/// One source a search tried.
public struct ProviderAttempt: Codable, Sendable, Hashable {
    public var provider: String
    public var ok: Bool
    public var skipped: Bool?
    public var count: Int?
    public var error: String?
}

public struct SearchResponse: Codable, Sendable {
    public var source: String          // provider that answered, "mock", or "none"
    public var results: [PartSummary]
    public var attempts: [ProviderAttempt]?

    /// Why the answering provider is not the first choice, e.g. "OEMsecrets: daily budget used".
    public var fallbackNote: String? {
        let failed = (attempts ?? []).filter { !$0.ok }
        guard !failed.isEmpty else { return nil }
        return failed.map { "\(PartsProvider.title(of: $0.provider)): \($0.error ?? "failed")" }.joined(separator: " · ")
    }
}

/// Which distributor data source to use.
public enum PartsProvider: String, CaseIterable, Sendable, Identifiable {
    case auto, trustedparts, mouser, digikey, oemsecrets, octopart
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: "Automatic"
        case .oemsecrets: "OEMsecrets"
        case .octopart: "Octopart"
        case .trustedparts: "TrustedParts"
        case .mouser: "Mouser"
        case .digikey: "Digi-Key"
        }
    }

    /// Title for any source name a search reports, including the parts database.
    public static func title(of source: String) -> String {
        if source == "library" { return "Parts library" }
        return PartsProvider(rawValue: source)?.title ?? source
    }
}

public struct OffersResponse: Codable, Sendable {
    public var offers: [String: PartSummary]
    public var missing: [String]
    public var errors: [String]
}

public struct DetailResponse: Codable, Sendable {
    public var part: PartSummary?
    /// Sources that contributed, in priority order.
    public var sources: [String]
    public var attempts: [ProviderAttempt]?
}

public struct ProviderUsage: Codable, Sendable, Hashable {
    public var callsToday: Int
    public var callsThisMonth: Int
    public var dailyLimit: Int?
    public var monthlyLimit: Int?
    public var unavailable: String?
}

/// Parts search for the app and `crimp`. By default it runs inside Loomo (PartsEngine) with the user's own API keys;
/// given a server address it talks to a self-hosted copy of the same service instead.
public struct PartsClient: Sendable {
    /// nil: the built-in engine.
    public var baseURL: URL?
    let engine: PartsEngine

    /// The built-in engine, with the credentials set in PartsEngine.shared.configure(_:).
    public static var local: PartsClient { PartsClient(baseURL: nil, engine: .shared) }

    public init(baseURL: URL?, engine: PartsEngine = .shared) {
        self.baseURL = baseURL
        self.engine = engine
    }

    public func search(_ query: String, category: PartCategory = .any, limit: Int = 20,
                       provider: PartsProvider = .auto) async throws -> SearchResponse {
        guard let baseURL else { return try await engine.search(query, category: category, limit: limit, provider: provider) }
        var comps = URLComponents(url: baseURL.appendingPathComponent("parts/search"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "category", value: category.rawValue),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "provider", value: provider.rawValue),
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw PartsError.server(http.statusCode, detail)
        }
        return try JSONDecoder().decode(SearchResponse.self, from: data)
    }
}

public extension PartsClient {
    /// Current price and stock for many MPNs (batched to spare API quotas).
    func offers(for mpns: [String]) async throws -> OffersResponse {
        guard let baseURL else { return await engine.offers(for: mpns) }
        var request = URLRequest(url: baseURL.appendingPathComponent("parts/offers"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["mpns": mpns])
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PartsError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(OffersResponse.self, from: data)
    }

    /// Everything known about one part number, merged across every configured source (cached in the parts database).
    func detail(mpn: String) async throws -> DetailResponse {
        guard let baseURL else { return await engine.detail(mpn: mpn) }
        var comps = URLComponents(url: baseURL.appendingPathComponent("parts/detail"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "mpn", value: mpn)]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PartsError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(DetailResponse.self, from: data)
    }

    func usage() async throws -> [String: ProviderUsage] {
        guard let baseURL else { return await engine.usage() }
        let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("usage"))
        return try JSONDecoder().decode([String: ProviderUsage].self, from: data)
    }
}

public enum PartsError: LocalizedError {
    case server(Int, String)
    case notSetUp(String)
    public var errorDescription: String? {
        switch self {
        case let .server(code, detail): "Parts service returned \(code): \(detail)"
        case let .notSetUp(source): "\(source) isn't set up. Add its API key in Settings ▸ Parts Sources."
        }
    }
}
