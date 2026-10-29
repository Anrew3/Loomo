import Foundation

/// Connector facts mined from distributor descriptions.
///
/// Distributors describe the same part in many styles ("8Ckt", "8POS", "8 Contacts, 1 Row", "08P",
/// "0.079 Inch Pitch"). Each description votes; the most common answer wins, so a single wrong listing
/// can't decide the result. A tie isn't trusted.
enum ConnectorFacts {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are fixed and tested, so a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let positionsRE = regex(
        #"(?<![\d.])0*(\d{1,3})\s*[- ]?\s*(?:pos(?:ition)?s?|ckts?|circuits?|crcts?|contacts?(?:\(s\))?|ways?|pins?|cavit(?:y|ies)|terminals?|p)(?![a-z])"#)
    private static let rowsRE = regex(#"(?<![\d.])(\d)\s*rows?(?:\(s\))?\b"#)
    private static let rowWords: [(String, Int)] = [("single row", 1), ("dual row", 2), ("double row", 2), ("two row", 2), ("triple row", 3)]
    private static let pitchMMRE = regex(#"(\d{1,2}(?:\.\d{1,3})?)\s*mm\b"#)
    private static let pitchInRE = regex(#"(0\.\d{2,4})\s*(?:"|in(?:ch)?\b)"#)
    private static let genderRE = regex(#"\b(female|male)\b"#)

    private static func groups(_ re: NSRegularExpression, _ s: String) -> [String] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    static func positions(_ d: String) -> Int? {
        groups(positionsRE, d).compactMap(Int.init).first { $0 > 0 && $0 <= 200 }
    }

    static func rows(_ d: String) -> Int? {
        let low = d.lowercased()
        if let hit = rowWords.first(where: { low.contains($0.0) }) { return hit.1 }
        return groups(rowsRE, d).first.flatMap(Int.init)
    }

    static func pitchMM(_ d: String) -> Double? {
        let low = d.lowercased()
        guard low.contains("pitch") || low.contains("mm") else { return nil }
        if low.contains("pitch"), let inches = groups(pitchInRE, d).first.flatMap(Double.init) {
            return (inches * 25.4 * 100).rounded() / 100
        }
        // Connector pitches only: ignores lengths and wire sizes.
        return groups(pitchMMRE, d).compactMap(Double.init).first { $0 >= 0.5 && $0 <= 10 }
    }

    static func gender(_ d: String) -> String? { groups(genderRE, d).first?.lowercased() }

    private static func vote<T: Hashable>(_ values: [T?]) -> T? {
        var counts: [T: Int] = [:]
        var order: [T] = []
        for v in values.compactMap({ $0 }) {
            if counts[v] == nil { order.append(v) }
            counts[v, default: 0] += 1
        }
        let ranked = order.sorted { counts[$0]! > counts[$1]! }
        guard let best = ranked.first else { return nil }
        if ranked.count > 1, counts[ranked[1]] == counts[best] { return nil }
        return best
    }

    /// "Positions", "Rows", "Pitch (mm)" and "Gender", when the descriptions agree.
    static func facts(_ descriptions: [String?]) -> [String: String] {
        let ds = descriptions.compactMap { $0 }.filter { !$0.isEmpty }
        var out: [String: String] = [:]
        if let n = vote(ds.map(positions)) { out["Positions"] = String(n) }
        if let r = vote(ds.map(rows)) { out["Rows"] = String(r) }
        if let p = vote(ds.map(pitchMM)) { out["Pitch (mm)"] = p == p.rounded() ? String(Int(p)) : String(p) }
        if let g = vote(ds.map(gender)) { out["Gender"] = g.prefix(1).uppercased() + g.dropFirst() }
        return out
    }
}
