import Foundation

// The distributor APIs Loomo can search, each with the user's own credentials. Every source turns its API's
// answer into PartSummary values; the engine (PartsEngine) chains them, caches answers and merges what each
// one knows about a part.

/// A provider refused because the key isn't accepted or the account is over its call limit. The engine
/// pauses that provider for a while instead of failing every search.
struct ProviderLimitError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One provider's result, with photo candidates the engine checks before keeping one.
struct SourcePart: Sendable {
    var part: PartSummary
    /// Photo URLs to try in order; nil keeps `part.imageURL` as given.
    var images: [String]?
}

protocol PartsSource: Sendable {
    var name: String { get }
    /// False when the API only searches by part number.
    var keywordSearch: Bool { get }
    func search(_ query: String, limit: Int) async throws -> [SourcePart]
}

/// "DT06-4S" and "dt06 4s" are the same part number.
func normMPN(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func string(_ k: String) -> String? {
        if let s = self[k] as? String { return s.isEmpty ? nil : s }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func dict(_ k: String) -> JSON { self[k] as? JSON ?? [:] }
    func list(_ k: String) -> [JSON] { self[k] as? [JSON] ?? [] }
    func number(_ k: String) -> Double? {
        if let n = self[k] as? NSNumber { return n.doubleValue }
        if let s = self[k] as? String { return Double(s) }
        return nil
    }
}

/// Sends a request and returns the status, decoded JSON (if any) and the body as text for error messages.
func fetchJSON(_ request: URLRequest, session: URLSession = .shared) async throws -> (status: Int, json: Any?, text: String) {
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    return (status, try? JSONSerialization.jsonObject(with: data), String(decoding: data.prefix(400), as: UTF8.self))
}

func request(_ url: URL, method: String = "GET", json body: Any? = nil, form: [String: String]? = nil,
             headers: [String: String] = [:], timeout: TimeInterval = 30) -> URLRequest {
    var r = URLRequest(url: url, timeoutInterval: timeout)
    r.httpMethod = method
    if let body {
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if let form {
        var c = URLComponents()
        c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        r.httpBody = Data((c.percentEncodedQuery ?? "").utf8)
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    }
    for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
    return r
}

func url(_ base: String, _ query: [String: String] = [:]) -> URL {
    var c = URLComponents(string: base)!
    if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
    return c.url!
}

private func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

// MARK: - Mouser

/// Mouser Search API v1: keyword and part-number search; 1,000 calls a day and 30 a minute per key.
/// Stock and prices for most parts, photos and datasheets for fewer.
struct MouserSource: PartsSource {
    let apiKey: String
    let name = "mouser"
    let keywordSearch = true

    static func price(_ text: String?) -> Double? {
        guard let text, let r = text.replacingOccurrences(of: ",", with: "").range(of: #"[\d.]+"#, options: .regularExpression) else { return nil }
        return Double(text.replacingOccurrences(of: ",", with: "")[r])
    }

    static func normalise(_ p: JSON) -> SourcePart {
        let desc = p.string("Description")
        var specs: [String: String] = [:]
        for a in p.list("ProductAttributes") {
            if let k = a.string("AttributeName"), let v = a.string("AttributeValue"), k != "Standard Pack Qty", k != "Packaging" { specs[k] = v }
        }
        specs.merge(ConnectorFacts.facts([desc])) { _, new in new }
        // Why a part may have no price or stock here: Mouser says so in these fields.
        for (key, label) in [("LeadTime", "Lead time"), ("LifecycleStatus", "Lifecycle"), ("RestrictionMessage", "Mouser note")] {
            if let v = p.string(key), specs[label] == nil { specs[label] = v }
        }
        let first = p.list("PriceBreaks").min { ($0.number("Quantity") ?? 0) < ($1.number("Quantity") ?? 0) }
        let stockText = p.string("AvailabilityInStock")
            ?? (p.string("Availability") ?? "").split(separator: " ").first.map { String($0.filter(\.isNumber)) } ?? ""
        var image = p.string("ImagePath") ?? p.string("ImageURL") ?? ""
        if image.hasPrefix("/") { image = "https://www.mouser.com" + image }
        let mpn = p.string("ManufacturerPartNumber") ?? ""
        let maker = p.string("Manufacturer") ?? ""
        let part = PartSummary(id: "mouser-\(normMPN(maker))-\(normMPN(mpn))", mpn: mpn, manufacturer: maker, description: desc,
                               category: p.string("Category"), datasheetURL: p.string("DataSheetUrl").flatMap(URL.init(string:)),
                               octopartURL: p.string("ProductDetailUrl").flatMap(URL.init(string:)),
                               medianPrice: price(first?.string("Price")), currency: first?.string("Currency"),
                               totalAvailable: Int(stockText), specs: specs, source: "mouser", distributors: 1)
        return SourcePart(part: part, images: image.isEmpty ? [] : [image])
    }

    func search(_ query: String, limit: Int) async throws -> [SourcePart] {
        let body: JSON = ["SearchByKeywordRequest": ["keyword": query, "records": min(limit, 50), "startingRecord": 0,
                                                     "searchOptions": "", "searchWithYourSignUpLanguage": ""]]
        let r = try await fetchJSON(request(url("https://api.mouser.com/api/v1/search/keyword", ["apiKey": apiKey]), method: "POST", json: body))
        if [401, 403, 429].contains(r.status) { throw ProviderLimitError(message: "Mouser HTTP \(r.status): key refused or over the call limit") }
        guard r.status == 200, let data = r.json as? JSON else { throw ProviderError(message: "Mouser HTTP \(r.status): \(r.text.prefix(200))") }
        let errors = data.list("Errors").map { $0.string("Message") ?? $0.string("Code") ?? "\($0)" }
        if !errors.isEmpty {
            let text = errors.joined(separator: "; ")
            if text.range(of: "limit|exceed|maximum", options: [.regularExpression, .caseInsensitive]) != nil {
                throw ProviderLimitError(message: "Mouser: \(text)")
            }
            throw ProviderError(message: "Mouser: \(text.prefix(200))")
        }
        // Mouser lists the same part once per packaging; keep the first of each, exact match first.
        var seen = Set<String>()
        var out = data.dict("SearchResults").list("Parts").map(Self.normalise).filter { seen.insert(normMPN($0.part.mpn)).inserted }
        let q = normMPN(query)
        out = out.filter { normMPN($0.part.mpn) == q } + out.filter { normMPN($0.part.mpn) != q }
        return Array(out.prefix(limit))
    }
}

// MARK: - Digi-Key

/// Digi-Key Product Information API v4, as an OAuth2 client-credentials app. Photos, datasheets and parametric
/// data for most parts, which makes it the best source for filling gaps.
actor DigiKeySource: PartsSource {
    nonisolated let name = "digikey"
    nonisolated let keywordSearch = true
    private let clientID: String, clientSecret: String, country: String, currency: String
    private var token: String?
    private var expires = Date.distantPast

    init(clientID: String, clientSecret: String, country: String, currency: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.country = country
        self.currency = currency
    }

    private func accessToken() async throws -> String {
        if let token, Date() < expires.addingTimeInterval(-60) { return token }
        let r = try await fetchJSON(request(URL(string: "https://api.digikey.com/v1/oauth2/token")!, method: "POST",
                                            form: ["client_id": clientID, "client_secret": clientSecret, "grant_type": "client_credentials"]))
        guard r.status == 200, let body = r.json as? JSON, let t = body.string("access_token") else {
            throw ProviderLimitError(message: "Digi-Key sign-in failed (HTTP \(r.status))")
        }
        token = t
        expires = Date().addingTimeInterval(body.number("expires_in") ?? 600)
        return t
    }

    static func normalise(_ p: JSON) -> SourcePart {
        let d = p.dict("Description")
        let text = d.string("DetailedDescription") ?? d.string("ProductDescription")
        var specs: [String: String] = [:]
        for x in p.list("Parameters") {
            if let k = x.string("ParameterText"), let v = x.string("ValueText"), v != "-" { specs[k] = v }
        }
        specs.merge(ConnectorFacts.facts([text])) { mine, _ in mine }
        if let series = p.dict("Series").string("Name"), specs["Series"] == nil { specs["Series"] = series }
        let mpn = p.string("ManufacturerProductNumber") ?? ""
        let maker = p.dict("Manufacturer").string("Name") ?? ""
        let photo = p.string("PhotoUrl") ?? ""
        let price = p.number("UnitPrice").flatMap { $0 > 0 ? $0 : nil }
        let stock = p.number("QuantityAvailable").map(Int.init).flatMap { $0 > 0 ? $0 : nil }
        let part = PartSummary(id: "digikey-\(normMPN(maker))-\(normMPN(mpn))", mpn: mpn, manufacturer: maker, description: text,
                               category: p.dict("Category").string("Name"), datasheetURL: p.string("DatasheetUrl").flatMap(URL.init(string:)),
                               octopartURL: p.string("ProductUrl").flatMap(URL.init(string:)), medianPrice: price,
                               currency: price == nil ? nil : "USD", totalAvailable: stock, specs: specs, source: "digikey", distributors: 1)
        return SourcePart(part: part, images: photo.isEmpty ? [] : [photo.hasPrefix("//") ? "https:" + photo : photo])
    }

    func search(_ query: String, limit: Int) async throws -> [SourcePart] {
        let t = try await accessToken()
        let r = try await fetchJSON(request(URL(string: "https://api.digikey.com/products/v4/search/keyword")!, method: "POST",
                                            json: ["Keywords": query, "Limit": min(limit, 50), "Offset": 0],
                                            headers: ["Authorization": "Bearer \(t)", "X-DIGIKEY-Client-Id": clientID,
                                                      "X-DIGIKEY-Locale-Site": country, "X-DIGIKEY-Locale-Currency": currency,
                                                      "X-DIGIKEY-Locale-Language": "en"]))
        if [401, 403, 429].contains(r.status) { throw ProviderLimitError(message: "Digi-Key HTTP \(r.status): not allowed or over the call limit") }
        guard r.status == 200, let data = r.json as? JSON else { throw ProviderError(message: "Digi-Key HTTP \(r.status): \(r.text.prefix(200))") }
        var seen = Set<String>()
        let items = (data.list("ExactMatches") + data.list("Products")).map(Self.normalise)
            .filter { let k = normMPN($0.part.mpn); return !k.isEmpty && seen.insert(k).inserted }
        return Array(items.prefix(limit))
    }
}

// MARK: - OEMsecrets

/// OEMsecrets Part Search API v3: one call returns every distributor offer for a full or partial part number.
/// Offers are grouped into parts (manufacturer + part number) with stock totalled, a median unit price, and the
/// best English description and photo picked across distributors.
struct OEMsecretsSource: PartsSource {
    let apiKey: String, country: String, currency: String
    var session: URLSession = .shared
    let name = "oemsecrets"
    let keywordSearch = false

    private static let badImage = try! NSRegularExpression(pattern: #"no[_-]?image|placeholder|/scripts/|default\.(png|jpg)"#, options: .caseInsensitive)
    private static let regionRank = ["north america": 0, "americas": 0, "global": 1, "europe": 2, "asia": 3]
    private static let unknownMakers: Set<String> = ["", "not specified", "n/a", "na", "unknown", "various", "generic"]

    func offers(for term: String) async throws -> [JSON] {
        let r = try await fetchJSON(request(url("https://oemsecretsapi.com/partsearch",
                                                ["apiKey": apiKey, "searchTerm": term, "countryCode": country, "currency": currency])), session: session)
        if r.status == 404 { return [] }
        if r.status == 401 { throw ProviderLimitError(message: "OEMsecrets: key not accepted or API call limit exceeded") }
        guard r.status == 200, let data = r.json as? JSON else { throw ProviderError(message: "OEMsecrets HTTP \(r.status): \(r.text.prefix(200))") }
        return data.list("stock")
    }

    func search(_ query: String, limit: Int) async throws -> [SourcePart] {
        Array(Self.group(try await offers(for: query), term: query, currency: currency).prefix(limit))
    }

    /// The best exact match for one part number (for BOM price refresh).
    func offer(_ mpn: String) async throws -> SourcePart? {
        Self.group(try await offers(for: mpn), term: mpn, currency: currency).first { normMPN($0.part.mpn) == normMPN(mpn) }
    }

    /// "deutsch / te connectivity" vs "TE Connectivity".
    private static func sameCompany(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count > 2 })
        }
        return !words(a).isDisjoint(with: words(b))
    }

    static func group(_ offers: [JSON], term: String, currency: String) -> [SourcePart] {
        struct Key: Hashable { let maker: String; let mpn: String }
        var groups: [Key: [JSON]] = [:]
        var order: [Key] = []
        for o in offers {
            let maker = o.string("canonical_manufacturer") ?? o.string("manufacturer") ?? ""
            let key = normMPN(o.string("part_number") ?? o.string("source_part_number") ?? "")
            guard !key.isEmpty else { continue }
            let k = Key(maker: maker, mpn: key)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(o)
        }
        // Marketplace sellers list the same part number under unknown or variant maker names; fold those offers
        // into the best-supported group for that part number.
        for mpn in Set(order.map(\.mpn)) {
            let keys = order.filter { $0.mpn == mpn && groups[$0] != nil }
            guard keys.count > 1, let main = keys.max(by: {
                let a = (!unknownMakers.contains($0.maker.lowercased()), groups[$0]!.count)
                let b = (!unknownMakers.contains($1.maker.lowercased()), groups[$1]!.count)
                return a.0 == b.0 ? a.1 < b.1 : !a.0
            }) else { continue }
            for k in keys where k != main {
                let minor = groups[k]!.count <= 2 && groups[main]!.count >= 5 * groups[k]!.count
                if unknownMakers.contains(k.maker.lowercased().trimmingCharacters(in: .whitespaces)) || sameCompany(k.maker, main.maker) || minor {
                    groups[main]!.append(contentsOf: groups.removeValue(forKey: k)!)
                }
            }
        }
        typealias Ranked = (part: SourcePart, exact: Bool, offers: Int, stock: Int)
        var parts: [Ranked] = []
        for k in order {
            guard let offs = groups[k] else { continue }
            let authorised = offs.filter { $0.string("distributor_authorisation_status") == "authorised" }.nilIfEmpty ?? offs
            let ranked = offs.sorted {
                regionRank[($0.dict("distributor").string("distributor_region") ?? "").lowercased()] ?? 5
                    < regionRank[($1.dict("distributor").string("distributor_region") ?? "").lowercased()] ?? 5
            }
            let mpn = mostCommon(offs.compactMap { $0.string("source_part_number") ?? $0.string("part_number") }) ?? k.mpn
            let descriptions = ranked.compactMap { $0.string("description") }
            let description = descriptions.first { $0.allSatisfy(\.isASCII) } ?? descriptions.first
            var images: [String] = []
            for o in ranked {
                if let u = o.string("image_url"), !images.contains(u),
                   badImage.firstMatch(in: u, range: NSRange(location: 0, length: (u as NSString).length)) == nil { images.append(u) }
            }
            let unitPrices: [Double] = authorised.compactMap { o in
                let breaks = (o.dict("prices")[currency] as? [JSON] ?? []).sorted { ($0.number("unit_break") ?? 0) < ($1.number("unit_break") ?? 0) }
                guard let p = breaks.first?.number("unit_price"), p > 0 else { return nil }
                return p
            }
            let stock = Int(authorised.reduce(0) { $0 + ($1.number("quantity_in_stock") ?? 0) })
            let distributors = Set(offs.compactMap { $0.dict("distributor").string("distributor_common_name") })
            let leads = offs.compactMap { $0.number("lead_time_weeks") }.filter { $0 > 0 }.map(Int.init)
            var specs = ConnectorFacts.facts(offs.map { $0.string("description") })
            specs["Distributors"] = String(distributors.count)
            specs["Offers"] = String(offs.count)
            if let lead = leads.min() { specs["Lead time (weeks)"] = String(lead) }
            if let life = mostCommon(offs.compactMap { $0.string("life_cycle") }) { specs["Lifecycle"] = life }
            if offs.contains(where: { ($0.dict("compliance")["rohs"] as? Bool) == true }) { specs["RoHS"] = "Yes" }
            let price = median(unitPrices).map { ($0 * 10_000).rounded() / 10_000 }
            let part = PartSummary(id: "oem-\(normMPN(k.maker))-\(k.mpn)", mpn: mpn, manufacturer: k.maker, description: description,
                                   category: offs.lazy.compactMap { $0.string("category") }.first,
                                   datasheetURL: ranked.lazy.compactMap { $0.string("datasheet_url") }.first.flatMap(URL.init(string:)),
                                   imageURL: images.first.flatMap(URL.init(string:)),
                                   octopartURL: ranked.lazy.compactMap { $0.string("buy_now_url") }.first.flatMap(URL.init(string:)),
                                   medianPrice: price, currency: price == nil ? nil : currency, totalAvailable: stock > 0 ? stock : nil,
                                   specs: specs, source: "oemsecrets", distributors: distributors.count)
            parts.append((SourcePart(part: part, images: Array(images.prefix(6))), normMPN(mpn) == normMPN(term), offs.count, stock))
        }
        // Exact part number first, then the most offers, then the most stock.
        return parts.sorted { a, b in
            if a.exact != b.exact { return a.exact }
            if a.offers != b.offers { return a.offers > b.offers }
            return a.stock > b.stock
        }.map(\.part)
    }

    private static func mostCommon(_ xs: [String]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for x in xs { if counts[x] == nil { order.append(x) }; counts[x, default: 0] += 1 }
        return order.max { counts[$0]! < counts[$1]! || (counts[$0]! == counts[$1]! && order.firstIndex(of: $0)! > order.firstIndex(of: $1)!) }
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

// MARK: - TrustedParts

/// TrustedParts.com Inventory API v2: part-number search across authorized distributors, with stock and
/// pricing but no photos or keyword search. Answers up to 50 part numbers per call, which suits BOM pricing.
struct TrustedPartsSource: PartsSource {
    let apiKey: String, companyID: String?, country: String, currency: String
    var session: URLSession = .shared
    let name = "trustedparts"
    let keywordSearch = false

    private func post(_ tokens: [String], exact: Bool) async throws -> JSON {
        var body: JSON = ["Queries": tokens.prefix(50).map { ["SearchToken": String($0.prefix(100))] }, "ExactMatch": exact,
                          "CountryCode": country, "CurrencyCode": currency, "UseCachedData": true, "IsCrawler": false,
                          "UserAgent": "Loomo"]
        if let companyID, !companyID.isEmpty { body["CompanyId"] = companyID }
        let r = try await fetchJSON(request(URL(string: "https://api.trustedparts.com/v2/search")!, method: "POST", json: body,
                                            headers: ["X-Api-Key": apiKey, "Accept": "application/json"], timeout: 20), session: session)
        if [401, 403, 429].contains(r.status) { throw ProviderLimitError(message: "TrustedParts HTTP \(r.status): key not accepted or request limit reached") }
        guard r.status == 200, let data = r.json as? JSON else { throw ProviderError(message: "TrustedParts HTTP \(r.status): \(r.text.prefix(200))") }
        if let e = data.string("ErrorMessage") { throw ProviderError(message: "TrustedParts: \(e)") }
        return data
    }

    func search(_ query: String, limit: Int) async throws -> [SourcePart] {
        Array(try await post([query], exact: false).list("PartResults").map(Self.normalise).prefix(limit))
    }

    /// Exact-match stock and pricing for up to 50 part numbers in one request, keyed by the part number asked for.
    func offers(_ mpns: [String]) async throws -> [String: SourcePart] {
        let data = try await post(mpns, exact: true)
        var byNorm: [String: String] = [:]
        for m in mpns { byNorm[normMPN(m)] = m }
        var out: [String: SourcePart] = [:]
        for p in data.list("PartResults") {
            if let key = byNorm[normMPN(p.string("PartNumber") ?? "")], out[key] == nil { out[key] = Self.normalise(p) }
        }
        return out
    }

    static func normalise(_ p: JSON) -> SourcePart {
        let dists = p.list("Distributors")
        let results = dists.flatMap { $0.list("DistributorResults") }
        let description = results.lazy.compactMap { $0.string("Description") }.first
        let datasheet = results.lazy.flatMap { $0.list("Links") }
            .first { ($0.string("Type") ?? "").lowercased() == "datasheet" && $0.string("Url") != nil }?.string("Url")
        let stock = results.reduce(0) { $0 + Int($1.dict("Stock").number("QuantityOnHand") ?? 0) }
        var unitPrices: [Double] = []
        var currency: String?
        for r in results {
            let pricing = r.dict("Pricing")
            let prices = pricing.list("Prices").filter { $0.number("Amount") != nil }.sorted { ($0.number("Quantity") ?? 0) < ($1.number("Quantity") ?? 0) }
            if let first = prices.first?.number("Amount") {
                unitPrices.append(first)
                currency = currency ?? pricing.string("CurrencyCode")
            }
        }
        var specs: [String: String] = [:]
        for s in p.list("Specifications") { if let k = s.string("Key"), let v = s.string("Value") { specs[k] = v } }
        let part = PartSummary(id: "tp-\(p.string("ManufacturerId") ?? "0")-\(p.string("PartNumber") ?? "")", mpn: p.string("PartNumber") ?? "",
                               manufacturer: p.string("Manufacturer") ?? "", description: description,
                               datasheetURL: datasheet.flatMap(URL.init(string:)), octopartURL: p.string("ProductUrl").flatMap(URL.init(string:)),
                               medianPrice: median(unitPrices), currency: currency, totalAvailable: stock > 0 ? stock : nil,
                               specs: specs, source: "trustedparts", distributors: dists.count)
        return SourcePart(part: part, images: nil)
    }
}

// MARK: - Octopart (Nexar)

/// Octopart data through the Nexar GraphQL API (OAuth2 client credentials). Nexar bills per matched part
/// returned, so results are capped.
actor NexarSource: PartsSource {
    nonisolated let name = "octopart"
    nonisolated let keywordSearch = true
    private let clientID: String, clientSecret: String
    private var token: String?
    private var expires = Date.distantPast
    static let resultLimit = 10

    static let query = """
        query Search($q: String!, $limit: Int!) {
          supSearch(q: $q, limit: $limit) {
            results {
              part {
                id mpn octopartUrl shortDescription
                manufacturer { name } category { name } bestDatasheet { url } bestImage { url }
                medianPrice1000 { price currency } totalAvail
                specs { attribute { shortname name } displayValue }
              }
            }
          }
        }
        """

    init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    private func accessToken() async throws -> String {
        if let token, Date() < expires.addingTimeInterval(-60) { return token }
        let r = try await fetchJSON(request(URL(string: "https://identity.nexar.com/connect/token")!, method: "POST",
                                            form: ["grant_type": "client_credentials", "client_id": clientID,
                                                   "client_secret": clientSecret, "scope": "supply.domain"], timeout: 20))
        guard r.status == 200, let body = r.json as? JSON, let t = body.string("access_token") else {
            throw ProviderError(message: "Nexar sign-in failed (HTTP \(r.status))")
        }
        token = t
        expires = Date().addingTimeInterval(body.number("expires_in") ?? 3600)
        return t
    }

    func search(_ query: String, limit: Int) async throws -> [SourcePart] {
        let t = try await accessToken()
        let r = try await fetchJSON(request(URL(string: "https://api.nexar.com/graphql")!, method: "POST",
                                            json: ["query": Self.query, "variables": ["q": query, "limit": min(limit, Self.resultLimit)]],
                                            headers: ["Authorization": "Bearer \(t)"], timeout: 20))
        if r.status == 429 { throw ProviderLimitError(message: "Nexar: rate or quota limit reached") }
        guard r.status == 200, let body = r.json as? JSON else { throw ProviderError(message: "Nexar HTTP \(r.status): \(r.text.prefix(200))") }
        if let message = body.list("errors").first?.string("message") {
            if ["limit", "quota", "exceeded"].contains(where: message.lowercased().contains) { throw ProviderLimitError(message: "Nexar: \(message)") }
            throw ProviderError(message: "Nexar: \(message)")
        }
        return body.dict("data").dict("supSearch").list("results").map { Self.normalise($0.dict("part")) }
    }

    static func normalise(_ p: JSON) -> SourcePart {
        let price = p.dict("medianPrice1000")
        var specs: [String: String] = [:]
        for s in p.list("specs") {
            let a = s.dict("attribute")
            if let k = a.string("shortname") ?? a.string("name"), let v = s.string("displayValue") { specs[k] = v }
        }
        let part = PartSummary(id: p.string("id") ?? "", mpn: p.string("mpn") ?? "", manufacturer: p.dict("manufacturer").string("name") ?? "",
                               description: p.string("shortDescription"), category: p.dict("category").string("name"),
                               datasheetURL: p.dict("bestDatasheet").string("url").flatMap(URL.init(string:)),
                               imageURL: p.dict("bestImage").string("url").flatMap(URL.init(string:)),
                               octopartURL: p.string("octopartUrl").flatMap(URL.init(string:)),
                               medianPrice: price.number("price"), currency: price.string("currency"),
                               totalAvailable: p.number("totalAvail").map(Int.init), specs: specs, source: "octopart")
        return SourcePart(part: part, images: nil)
    }
}
