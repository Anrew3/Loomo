import CrimpCore
import Foundation
import PartsClient
import Security
import SwiftUI

/// The user's distributor API keys, in the macOS Keychain (encrypted, and only this app can read them without
/// asking). Non-secret choices (search order, country, currency) live in UserDefaults. Nothing goes in a file.
enum PartsCredentials {
    private static let service = "com.loomo.Loomo.parts"

    /// One field a source needs.
    struct Field: Identifiable, Hashable {
        let key: String
        let label: String
        let secret: Bool
        var id: String { key }
    }

    /// A parts source as the setup screens describe it.
    struct Source: Identifiable, Hashable {
        let provider: PartsProvider
        let summary: String
        let signUp: URL
        let fields: [Field]
        var id: String { provider.rawValue }
    }

    static let sources: [Source] = [
        Source(provider: .mouser, summary: "Keyword and part-number search with stock, prices and many photos. Free key, 1,000 searches a day.",
               signUp: URL(string: "https://www.mouser.com/api-search/")!,
               fields: [Field(key: "mouser.key", label: "Search API key", secret: true)]),
        Source(provider: .digikey, summary: "Photos, datasheets and detailed specs for most parts. Free; create an app with the Product Information v4 API.",
               signUp: URL(string: "https://developer.digikey.com/")!,
               fields: [Field(key: "digikey.id", label: "Client ID", secret: false), Field(key: "digikey.secret", label: "Client secret", secret: true)]),
        Source(provider: .trustedparts, summary: "Stock and pricing from authorized distributors, 50 parts per call. Good for pricing a BOM.",
               signUp: URL(string: "https://www.trustedparts.com/en/api")!,
               fields: [Field(key: "trustedparts.key", label: "API key", secret: true)]),
        Source(provider: .oemsecrets, summary: "Every distributor's offers for a part number, with photos.",
               signUp: URL(string: "https://www.oemsecrets.com/api")!,
               fields: [Field(key: "oemsecrets.key", label: "API key", secret: true)]),
        Source(provider: .octopart, summary: "Octopart's catalog through Nexar. Free tier with a monthly part limit.",
               signUp: URL(string: "https://nexar.com/api")!,
               fields: [Field(key: "nexar.id", label: "Client ID", secret: false), Field(key: "nexar.secret", label: "Client secret", secret: true)]),
    ]

    // MARK: Keychain

    // Keys live in the data protection keychain, which belongs to the developer team rather than one exact build:
    // every signed Loomo, including updates, reads them with no password prompt. Builds without a signing team
    // can't use it, so they fall back to the login keychain. Keys an older build left in the login keychain move
    // over when Loomo can read them without asking; otherwise they're left alone and never prompt.

    private static func query(_ key: String, protected: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        if protected { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// False for unsigned builds, which have no keychain access group for the data protection keychain.
    nonisolated(unsafe) private static var dataProtectionAvailable = true

    static func value(_ key: String) -> String {
        if dataProtectionAvailable {
            var q = query(key, protected: true)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data { return String(decoding: data, as: UTF8.self) }
            if status == errSecMissingEntitlement { dataProtectionAvailable = false }
        }
        // The login keychain, never showing a password prompt.
        var legacy = query(key, protected: false)
        legacy[kSecReturnData as String] = true
        legacy[kSecMatchLimit as String] = kSecMatchLimitOne
        legacy[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var item: CFTypeRef?
        guard SecItemCopyMatching(legacy as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        let value = String(decoding: data, as: UTF8.self)
        if dataProtectionAvailable, store(key, value, protected: true) {
            SecItemDelete(query(key, protected: false) as CFDictionary)
        }
        return value
    }

    /// Stores a value; an empty one removes it.
    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if dataProtectionAvailable, store(key, trimmed, protected: true) { return true }
        return store(key, trimmed, protected: false)
    }

    private static func store(_ key: String, _ value: String, protected: Bool) -> Bool {
        let base = query(key, protected: protected)
        guard !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        if update == errSecMissingEntitlement { dataProtectionAvailable = false; return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Loomo parts source"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecMissingEntitlement { dataProtectionAvailable = false }
        return status == errSecSuccess
    }

    // MARK: Settings for the engine

    static var settings: PartsSettings {
        var s = PartsSettings()
        s.mouserKey = value("mouser.key")
        s.digikeyClientID = value("digikey.id")
        s.digikeyClientSecret = value("digikey.secret")
        s.trustedPartsKey = value("trustedparts.key")
        s.trustedPartsCompanyID = value("trustedparts.company")
        s.oemsecretsKey = value("oemsecrets.key")
        s.nexarClientID = value("nexar.id")
        s.nexarClientSecret = value("nexar.secret")
        let d = UserDefaults.standard
        if let order = d.stringArray(forKey: "parts.order"), !order.isEmpty { s.order = order }
        if let c = d.string(forKey: "parts.country"), !c.isEmpty { s.country = c }
        if let c = d.string(forKey: "parts.currency"), !c.isEmpty { s.currency = c }
        return s
    }

    /// Hands the current keys to the parts engine. Call after any change.
    static func apply() {
        let s = settings
        Task { await PartsEngine.shared.configure(s) }
    }

    /// At launch: configure the engine, and drop the address of the old local Python backend, which Loomo
    /// no longer needs (a self-hosted service at another address is kept).
    static func start() {
        let d = UserDefaults.standard
        if let old = d.string(forKey: PartsService.customKey), old.contains("127.0.0.1:8000") || old.contains("localhost:8000") {
            d.removeObject(forKey: PartsService.customKey)
        }
        apply()
    }

    static var anyConfigured: Bool { !settings.configured.isEmpty }

    /// Reads keys from a .env file (the old backend's format), for people moving from a source checkout.
    /// Returns the sources it found keys for.
    static func importEnv(_ url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let map = ["MOUSER_API_KEY": "mouser.key", "DIGIKEY_CLIENT_ID": "digikey.id", "DIGIKEY_CLIENT_SECRET": "digikey.secret",
                   "TRUSTEDPARTS_API_KEY": "trustedparts.key", "TRUSTEDPARTS_COMPANY_ID": "trustedparts.company",
                   "OEMSECRETS_API_KEY": "oemsecrets.key", "NEXAR_CLIENT_ID": "nexar.id", "NEXAR_CLIENT_SECRET": "nexar.secret"]
        var found: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].hasPrefix("#"), let key = map[parts[0]] else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty, set(key, value) { found.append(String(key.split(separator: ".")[0])) }
        }
        apply()
        return Array(Set(found)).sorted()
    }
}

/// Where parts searches go: the built-in engine, or a self-hosted parts service if the user set one.
enum PartsService {
    static let customKey = "partsBackendURL"

    static func client(_ setting: String? = UserDefaults.standard.string(forKey: customKey)) -> PartsClient {
        if let setting, !setting.isEmpty, let url = URL(string: setting) { return PartsClient(baseURL: url) }
        return .local
    }
}

/// The keys for one source, with a Test button that makes one real search.
struct PartsSourceForm: View {
    let source: PartsCredentials.Source
    @State private var values: [String: String] = [:]
    @State private var result: String?
    @State private var failed = false
    @State private var testing = false

    private var complete: Bool { source.fields.allSatisfy { !(values[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(source.provider.title).font(.headline)
                Spacer()
                Link("Get a key", destination: source.signUp).font(.callout)
            }
            Text(source.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(source.fields) { field in
                let binding = Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0; result = nil })
                if field.secret {
                    SecureField(field.label, text: binding).textFieldStyle(.roundedBorder)
                } else {
                    TextField(field.label, text: binding).textFieldStyle(.roundedBorder)
                }
            }
            HStack(spacing: 10) {
                Button(testing ? "Testing…" : "Save and Test") { Task { await saveAndTest() } }
                    .disabled(!complete || testing)
                if !(values.values.allSatisfy(\.isEmpty)) {
                    Button("Remove", role: .destructive) {
                        for f in source.fields { PartsCredentials.set(f.key, "") }
                        values = [:]
                        result = nil
                        PartsCredentials.apply()
                    }
                }
                if let result {
                    Label(result, systemImage: failed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(failed ? .red : .green).lineLimit(2)
                }
            }
        }
        .onAppear { for f in source.fields { values[f.key] = PartsCredentials.value(f.key) } }
    }

    private func saveAndTest() async {
        for f in source.fields { PartsCredentials.set(f.key, values[f.key] ?? "") }
        let settings = PartsCredentials.settings
        await PartsEngine.shared.configure(settings)
        testing = true
        defer { testing = false }
        do {
            result = try await PartsEngine.shared.test(source.provider)
            failed = false
        } catch {
            result = error.localizedDescription
            failed = true
        }
    }
}
