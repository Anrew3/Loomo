import Foundation
@testable import PartsClient
import Testing

// The built-in parts engine, which replaced the Python backend. These are the backend's tests, ported: no network,
// sources are fakes or talk to a stubbed URL loader.

private func fixture(_ name: String) throws -> [JSON] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? JSON)?.list("stock") ?? []
}

private func part(_ mpn: String, _ source: String, image: String? = nil, datasheet: String? = nil, description: String? = nil,
                  specs: [String: String] = [:]) -> PartSummary {
    PartSummary(id: "\(source)-\(mpn)", mpn: mpn, manufacturer: "TE", description: description,
                datasheetURL: datasheet.flatMap(URL.init(string:)), imageURL: image.flatMap(URL.init(string:)), specs: specs, source: source)
}

/// A source that answers from a list (or fails), counting its calls.
private final class Fake: PartsSource, @unchecked Sendable {
    let name: String
    let keywordSearch: Bool
    var results: [PartSummary]
    var error: Error?
    private(set) var queries: [String] = []

    init(_ name: String, _ results: [PartSummary] = [], error: Error? = nil, keyword: Bool = false) {
        self.name = name
        self.results = results
        self.error = error
        self.keywordSearch = keyword
    }

    func search(_ query: String, limit: Int) async throws -> [SourcePart] {
        queries.append(query)
        if let error { throw error }
        return results.map { SourcePart(part: $0, images: nil) }
    }
}

private func engine(_ sources: [any PartsSource]) async -> PartsEngine {
    let e = PartsEngine(storeURL: nil)
    await e.use(sources)
    return e
}

@Suite struct OEMsecretsGroupingTests {
    @Test func groupsOffersIntoParts() throws {
        let parts = OEMsecretsSource.group(try fixture("oemsecrets_dt06-4s"), term: "DT06-4S", currency: "USD")
        #expect(parts.prefix(2).map(\.part.mpn) == ["DT06-4S", "DT06-4S-CE13"])   // exact match first
        let dt = parts[0].part
        #expect(dt.manufacturer == "TE Connectivity")
        #expect((dt.totalAvailable ?? 0) > 0)
        #expect(dt.medianPrice != nil && dt.currency == "USD")
        #expect(dt.description.map { $0.allSatisfy(\.isASCII) } == true)        // English preferred
        #expect(dt.specs["Offers"] == "8")
        #expect(dt.source == "oemsecrets")
        #expect(!(dt.imageURL?.absoluteString.contains("/scripts/") ?? false))  // placeholder hosts skipped
    }

    @Test func mergesManufacturerVariants() throws {
        let stock = try fixture("oemsecrets_dt06-4s")
        var base = stock[0]
        base["distributor_authorisation_status"] = "independent"
        let variants: [JSON] = ["deutsch / te connectivity", "Not Specified"].map { m in
            var o = base; o["manufacturer"] = m; o["canonical_manufacturer"] = m; return o
        }
        // A different maker with several offers of its own is a real, separate part.
        let unrelated: [JSON] = (0..<3).map { i in
            var o = stock[0]; o["manufacturer"] = "Acme Widgets"; o["canonical_manufacturer"] = "Acme Widgets"; o["sku"] = "\(i)"; return o
        }
        let dt = OEMsecretsSource.group(stock + variants + unrelated, term: "DT06-4S", currency: "USD").map(\.part).filter { $0.mpn == "DT06-4S" }
        #expect(dt.map(\.manufacturer) == ["TE Connectivity", "Acme Widgets"])
        #expect(dt[0].specs["Offers"] == "10")
    }

    @Test func minorListingsFoldIntoTheMainPart() throws {
        let stock = try fixture("oemsecrets_dt06-4s")
        var minor = stock[0]
        minor["manufacturer"] = "ladd industries"
        minor["canonical_manufacturer"] = "ladd industries"
        let dt = OEMsecretsSource.group(stock + [minor], term: "DT06-4S", currency: "USD").map(\.part).filter { $0.mpn == "DT06-4S" }
        #expect(dt.map(\.manufacturer) == ["TE Connectivity"])
    }

    @Test func majorityVoteBeatsAWrongListing() throws {
        let part = try #require(OEMsecretsSource.group(try fixture("oemsecrets_502351-0801"), term: "502351-0801", currency: "USD")
            .map(\.part).first { $0.mpn.replacingOccurrences(of: "-", with: "") == "5023510801" })
        // Mouser lists "10 Crcts"; every other distributor says 8.
        #expect(part.specs["Positions"] == "8")
        #expect(part.specs["Rows"] == "1")
        #expect(part.specs["Pitch (mm)"] == "2")
        #expect(part.specs["Gender"] == "Female")
    }
}

@Suite struct ConnectorFactsTests {
    @Test(arguments: [
        ("2.0 W/B Rec Hsg 8Ckt Black", 8), ("CONN HOUSING, RCPT, 8POS, 2MM, BLACK;", 8),
        ("Connector Housing, Receptacle, 8 Contacts, 1 Row, 2 mm", 8), ("08P DURACLIK 2,00MM HOUS BLACK", 8),
        ("8 Position Rectangular Housing", 8), ("Board Connector, 8 Contact(S), 1 Row(S), Female", 8),
        ("Automotive Connector Housing, IP68, DT, Plug, 4 Ways", 4), ("PLUG HOUSING, 4POS, PA GF, GREY", 4),
        ("DT socket contact, size 16, 16-20 AWG", 0), ("Heat shrink 3:1", 0),
    ])
    func positions(_ description: String, _ n: Int) {
        #expect(ConnectorFacts.positions(description) == (n == 0 ? nil : n))
    }

    @Test func pitch() {
        #expect(ConnectorFacts.pitchMM("8 Position Housing Black 0.079\" (2.00mm)") == 2.0)
        #expect(ConnectorFacts.pitchMM("Board Connector, 0.079 Inch Pitch, Crimp") == 2.01)
        #expect(ConnectorFacts.pitchMM("Heat shrink, 25 mm") == nil)
    }

    @Test func tiesAreNotTrusted() {
        #expect(ConnectorFacts.facts(["4 Pos", "6 Pos"])["Positions"] == nil)
    }
}

@Suite struct ProviderNormalisingTests {
    @Test func mouserAndDigiKey() {
        let m = MouserSource.normalise([
            "ManufacturerPartNumber": "DT06-4S", "Manufacturer": "TE Connectivity / DEUTSCH",
            "Description": "Automotive Connectors PLUG DT 4 WAY", "ImagePath": "/images/te/dt06.jpg", "LeadTime": "84 Days",
            "DataSheetUrl": "", "Availability": "60623 In Stock", "Category": "Automotive Connectors",
            "PriceBreaks": [["Quantity": 10, "Price": "$1.50", "Currency": "USD"], ["Quantity": 1, "Price": "$1.77", "Currency": "USD"]],
            "ProductAttributes": [["AttributeName": "Standard Pack Qty", "AttributeValue": "1"]],
            "ProductDetailUrl": "https://www.mouser.com/ProductDetail/DT06-4S",
        ])
        #expect(m.part.medianPrice == 1.77 && m.part.totalAvailable == 60623 && m.part.datasheetURL == nil)
        #expect(m.images == ["https://www.mouser.com/images/te/dt06.jpg"] && m.part.specs["Positions"] == "4")
        #expect(m.part.specs["Lead time"] == "84 Days")
        let d = DigiKeySource.normalise([
            "ManufacturerProductNumber": "DT06-4S", "Manufacturer": ["Name": "TE Connectivity Deutsch"],
            "Description": ["ProductDescription": "CONN PLUG HSG 4POS", "DetailedDescription": "4 Position Plug"],
            "PhotoUrl": "//mm.digikey.com/dt06.jpg", "DatasheetUrl": "https://ds/dt06.pdf", "UnitPrice": 2.1,
            "QuantityAvailable": 50, "Parameters": [["ParameterText": "Number of Positions", "ValueText": "4"]],
        ])
        #expect(d.images == ["https://mm.digikey.com/dt06.jpg"] && d.part.specs["Number of Positions"] == "4")
        #expect(d.part.description == "4 Position Plug" && d.part.source == "digikey")
    }

    @Test func trustedParts() {
        let r = TrustedPartsSource.normalise(["PartNumber": "DT06-4S", "Manufacturer": "TE Connectivity", "ManufacturerId": 7,
            "Distributors": [["Id": 1, "Name": "A", "DistributorResults": [["Description": "DT plug 4 way",
                "Stock": ["QuantityOnHand": 120], "Links": [["Type": "datasheet", "Url": "https://x/ds.pdf"]],
                "Pricing": ["CurrencyCode": "USD", "Prices": [["Quantity": 100, "Amount": 2.1], ["Quantity": 1, "Amount": 3.0]]]]]],
                ["Id": 2, "Name": "B", "DistributorResults": [["Stock": ["QuantityOnHand": 30],
                "Pricing": ["CurrencyCode": "USD", "Prices": [["Quantity": 1, "Amount": 4.0]]]]]]]]).part
        #expect(r.totalAvailable == 150 && r.medianPrice == 3.5 && r.datasheetURL?.absoluteString == "https://x/ds.pdf")
    }
}

@Suite struct PartsEngineChainTests {
    @Test func firstSourceWinsAndTheNextFillsThePhoto() async throws {
        let e = await engine([Fake("oemsecrets", [part("DT06-4S", "oemsecrets")]), Fake("octopart", [part("X", "octopart")], keyword: true)])
        let r = try await e.search("DT06-4S")
        #expect(r.source == "oemsecrets")
        #expect(r.attempts?.map(\.provider) == ["oemsecrets", "octopart"])
    }

    @Test func fallsBackOnALimitErrorThenPauses() async throws {
        let e = await engine([Fake("oemsecrets", error: ProviderLimitError(message: "over limit")),
                              Fake("octopart", [part("DT06-4S", "octopart")], keyword: true)])
        let r = try await e.search("DT06-4S")
        #expect(r.source == "octopart")
        #expect(r.attempts?.first == ProviderAttempt(provider: "oemsecrets", ok: false, error: "over limit"))
        let again = try await e.search("DT04-2P")
        #expect(again.attempts?.first?.skipped == true && again.attempts?.first?.error?.contains("paused") == true)
    }

    @Test func fallsBackOnEmptyResultsAndReusesPhotos() async throws {
        let photo = Fake("octopart", [part("W4S", "octopart", image: "https://img/w4s.jpg")], keyword: true)
        let tp = Fake("trustedparts", [part("W4S", "trustedparts")])
        let e = await engine([photo, tp])
        _ = try await e.search("W4S", provider: .octopart)            // remembers the photo
        await e.use([Fake("oemsecrets"), tp])
        let r = try await e.search("W4S")
        #expect(r.source == "trustedparts")
        #expect(r.results.first?.imageURL?.absoluteString == "https://img/w4s.jpg")
    }

    @Test func partNumberSourcesSkipKeywordQueries() async throws {
        let e = await engine([Fake("oemsecrets", [part("A1", "oemsecrets")]), Fake("octopart", [part("B2", "octopart")], keyword: true)])
        let r = try await e.search("superseal 2 way")
        #expect(r.source == "octopart" && r.attempts?.first?.skipped == true)
    }

    @Test func dailyBudgetSkipsASource() async throws {
        let e = await engine([Fake("oemsecrets", [part("DT06-4S", "oemsecrets")]), Fake("octopart", [part("DT06-4S", "octopart")], keyword: true)])
        await e.setDailyLimit("oemsecrets", 1)
        #expect(try await e.search("DT06-4S").source == "oemsecrets")
        #expect(try await e.search("DT04-2P").source == "octopart")   // budget used up
        #expect(await e.usage()["oemsecrets"]?.callsToday == 1)
    }

    @Test func cacheAvoidsRepeatCalls() async throws {
        let oem = Fake("oemsecrets", [part("DT06-4S", "oemsecrets")])
        let e = await engine([oem])
        _ = try await e.search("DT06-4S")
        _ = try await e.search("dt06-4s")
        #expect(oem.queries.count == 1)
    }

    @Test func sampleCatalogWithoutKeys() async throws {
        let r = try await PartsEngine(storeURL: nil).search("DT", category: .connector)
        #expect(r.source == "mock" && !r.results.isEmpty)
    }

    @Test func aChosenSourceMustBeSetUp() async {
        let e = await engine([Fake("oemsecrets", [part("A1", "oemsecrets")])])
        await #expect(throws: PartsError.self) { try await e.search("A1", provider: .trustedparts) }
    }

    @Test func mixedQuerySearchesThePartNumberWord() async throws {
        let tp = Fake("trustedparts", [
            PartSummary(id: "1", mpn: "PTN0.25BK", manufacturer: "Techflex", description: "Expandable sleeving", specs: [:]),
            PartSummary(id: "2", mpn: "PTN0.25-X", manufacturer: "Other", description: "Relay", specs: [:]),
        ])
        let e = await engine([tp])
        let r = try await e.search("techflex PTN0.25BK", category: .covering)
        #expect(tp.queries == ["PTN0.25BK"])
        #expect(r.results.map(\.manufacturer) == ["Techflex"])
    }

    @Test func resultsAreEnrichedFromOtherSources() async throws {
        let tp = Fake("trustedparts", [part("DT06-4S", "trustedparts", specs: ["Number of Positions": "4 Position"])])
        let oem = Fake("oemsecrets", [part("DT06-4S", "oemsecrets", image: "https://img/dt.jpg", datasheet: "https://ds",
                                           specs: ["Positions": "4", "Lead time (weeks)": "1"])])
        let e = await engine([tp, oem])
        _ = try await e.search("DT06-4S", provider: .oemsecrets)    // OEMsecrets seen once
        let r = try await e.search("DT06-4S")                       // TrustedParts answers
        let hit = try #require(r.results.first)
        #expect(r.source == "trustedparts")
        #expect(hit.imageURL?.absoluteString == "https://img/dt.jpg" && hit.datasheetURL?.absoluteString == "https://ds")
        #expect(hit.specs["Number of Positions"] == "4 Position")   // TrustedParts wording kept
        #expect(hit.specs["Positions"] == nil)                      // same fact, not duplicated
        #expect(hit.specs["Lead time (weeks)"] == "1")
    }

    @Test func detailMergesAndAsksEachSourceOnce() async throws {
        let tp = Fake("trustedparts", [part("502351-0801", "trustedparts", specs: ["Number of Rows": "1 Row"])])
        let oem = Fake("oemsecrets", [part("502351-0801", "oemsecrets", image: "https://img/molex.jpg")])
        let e = await engine([tp, oem])
        let d = await e.detail(mpn: "502351-0801")
        #expect(d.sources == ["trustedparts", "oemsecrets"])
        #expect(d.part?.imageURL?.absoluteString == "https://img/molex.jpg" && d.part?.specs["Number of Rows"] == "1 Row")
        _ = await e.detail(mpn: "5023510801")
        #expect(tp.queries.count == 1 && oem.queries.count == 1)    // asked once each
    }

    @Test func detailRemembersMisses() async {
        let oem = Fake("oemsecrets")
        let e = await engine([oem])
        #expect(await e.detail(mpn: "ZZ-404").part == nil)
        _ = await e.detail(mpn: "ZZ-404")
        #expect(oem.queries.count == 1)
    }

    @Test func missingFieldsAreFilledDownTheLineWithCredit() async throws {
        let e = await engine([
            Fake("trustedparts", [part("DT06-4S", "trustedparts", description: "Plug 4 way")]),
            Fake("mouser", [part("DT06-4S", "mouser", datasheet: "https://ds/dt")], keyword: true),
            Fake("digikey", [part("DT06-4S", "digikey", image: "https://img/dt.jpg")], keyword: true),
            Fake("oemsecrets", [part("DT06-4S", "oemsecrets", image: "https://img/other.jpg")]),
        ])
        let r = try await e.search("DT06-4S")
        let hit = try #require(r.results.first)
        #expect(r.attempts?.map(\.provider) == ["trustedparts", "mouser", "digikey"])   // stops once complete
        #expect(hit.imageURL?.absoluteString == "https://img/dt.jpg" && hit.datasheetURL?.absoluteString == "https://ds/dt")
        #expect(hit.fieldSources == ["description": "trustedparts", "datasheetURL": "mouser", "imageURL": "digikey"])
        #expect(hit.sources == ["trustedparts", "mouser", "digikey"])
    }

    @Test func aKnownPartIsAnsweredWithoutCalls() async throws {
        let mouser = Fake("mouser", [part("W4S", "mouser", image: "https://img/w4s.jpg", datasheet: "https://ds", description: "Wedgelock")], keyword: true)
        let e = await engine([mouser])
        _ = try await e.search("W4S")
        let again = try await e.search("w4s")
        #expect(again.source == "library" && again.results.first?.imageURL?.absoluteString == "https://img/w4s.jpg")
        #expect(mouser.queries.count == 1)
        // Keyword searches include parts the database knows.
        #expect(try await e.search("wedgelock", provider: .mouser).results.first?.mpn == "W4S")
    }

    @Test func photoCandidatesThatArePagesAreSkipped() async throws {
        struct Pages: PartsSource {
            let name = "oemsecrets", keywordSearch = false
            func search(_ q: String, limit: Int) async throws -> [SourcePart] {
                [SourcePart(part: part("DT06-4S", "oemsecrets"), images: ["https://a/page", "https://b/photo.jpg"])]
            }
        }
        let e = await engine([Pages()])
        await e.setImageCheck { $0.host == "b" }
        #expect(try await e.search("DT06-4S").results.first?.imageURL?.absoluteString == "https://b/photo.jpg")
    }

    @Test func theDatabaseSurvivesARestart() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("parts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = PartsEngine(storeURL: file)
        await first.use([Fake("mouser", [part("W4S", "mouser", image: "https://i/w.jpg", datasheet: "https://d", description: "Wedgelock")], keyword: true)])
        _ = try await first.search("W4S")
        let second = PartsEngine(storeURL: file)
        await second.use([Fake("mouser", keyword: true)])
        #expect(try await second.search("W4S").source == "library")
    }
}

/// Answers HTTP requests from a handler instead of the network, and records what was sent.
final class StubLoader: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data?) -> (Int, Data))?
    nonisolated(unsafe) static var sent: [(URLRequest, Data?)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close()
            body = data
        }
        Self.sent.append((request, body))
        let (status, data) = Self.handler?(request, body) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The requests each source sends, checked against a stub. One at a time: the stub is shared.
@Suite(.serialized) struct SourceRequestTests {
    let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubLoader.self]
        return URLSession(configuration: c)
    }()

    @Test func oemsecretsRequestAndErrors() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["stock": try fixture("oemsecrets_dt06-4s")])
        StubLoader.sent = []
        StubLoader.handler = { _, _ in (200, body) }
        let source = OEMsecretsSource(apiKey: "KEY", country: "US", currency: "USD", session: session)
        let parts = try await source.search("DT06-4S", limit: 5)
        let query = URLComponents(url: try #require(StubLoader.sent.first?.0.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
                == ["apiKey": "KEY", "searchTerm": "DT06-4S", "countryCode": "US", "currency": "USD"])
        #expect(parts.first?.part.mpn == "DT06-4S")
        #expect(try await source.offer("dt064s")?.part.mpn == "DT06-4S")

        StubLoader.handler = { _, _ in (401, Data()) }
        await #expect(throws: ProviderLimitError.self) { try await source.search("DT06", limit: 5) }
        StubLoader.handler = { _, _ in (404, Data()) }
        #expect(try await source.search("ZZZZ99", limit: 5).isEmpty)
    }

    @Test func trustedPartsRequest() async throws {
        let sample: JSON = ["PartResults": [["PartNumber": "DT06-4S", "Manufacturer": "TE Connectivity", "Distributors": []]]]
        let data = try JSONSerialization.data(withJSONObject: sample)
        StubLoader.sent = []
        StubLoader.handler = { _, _ in (200, data) }
        let source = TrustedPartsSource(apiKey: "KEY", companyID: nil, country: "US", currency: "USD", session: session)
        _ = try await source.search("DT06", limit: 5)
        let (request, body) = try #require(StubLoader.sent.first)
        let sent = try #require(try JSONSerialization.jsonObject(with: body ?? Data()) as? JSON)
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "KEY")
        #expect((sent["Queries"] as? [[String: String]]) == [["SearchToken": "DT06"]])
        #expect(try await source.offers(["DT06-4S"])["DT06-4S"] != nil)
        let exact = try JSONSerialization.jsonObject(with: StubLoader.sent.last?.1 ?? Data()) as? JSON
        #expect(exact?["ExactMatch"] as? Bool == true)
    }
}

/// Real API calls with real keys, read from the .env file named by LOOMO_LIVE_ENV. Off unless that's set,
/// so normal runs and CI never touch the network or anyone's quota.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOOMO_LIVE_ENV"] != nil)) struct LiveSourceTests {
    @Test func eachConfiguredSourceAnswers() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LOOMO_LIVE_ENV"])
        var env: [String: String] = [:]
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") where line.contains("=") && !line.hasPrefix("#") {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            env[kv[0]] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        var s = PartsSettings()
        s.mouserKey = env["MOUSER_API_KEY"] ?? ""
        s.oemsecretsKey = env["OEMSECRETS_API_KEY"] ?? ""
        s.trustedPartsKey = env["TRUSTEDPARTS_API_KEY"] ?? ""
        s.trustedPartsCompanyID = env["TRUSTEDPARTS_COMPANY_ID"] ?? ""
        let e = PartsEngine(storeURL: nil)
        await e.configure(s)
        for name in await e.configured {
            let provider = try #require(PartsProvider(rawValue: name))
            do {
                let message = try await e.test(provider)
                print("LIVE \(name): \(message)")
            } catch {
                Issue.record("\(name) failed: \(error.localizedDescription)")
            }
        }
    }
}
