import Foundation

public enum WireTables {
    /// Nominal conductor cross-section for common automotive AWG sizes.
    public static let awgToMM2: [Int: Double] = [
        26: 0.13, 24: 0.20, 22: 0.33, 20: 0.52, 18: 0.82,
        16: 1.31, 14: 2.08, 12: 3.31, 10: 5.26, 8: 8.37, 6: 13.3, 4: 21.2,
    ]

    /// Approximate TXL outer diameters (SAE J1128), used when a wire has no explicit OD.
    static let txlODByAWG: [Int: Double] = [
        22: 1.17, 20: 1.32, 18: 1.55, 16: 1.80, 14: 2.13, 12: 2.59, 10: 3.23, 8: 4.10,
    ]

    /// IEC 60757 colours (used for the canvas and the WireViz export).
    public static let iecColors: [String: String] = [
        "BK": "#000000", "BN": "#8B4513", "RD": "#D00000", "OG": "#FF8000", "YE": "#FFD700",
        "GN": "#00A000", "BU": "#0050D0", "VT": "#8000C0", "GY": "#808080", "WH": "#FFFFFF",
        "PK": "#FF80C0", "TQ": "#40E0D0", "GD": "#D4AF37", "SR": "#C0C0C0",
        // Shades used on automotive drawings beyond IEC 60757.
        "LB": "#7EC8F8", "LG": "#90E090", "DB": "#00308F", "DG": "#006000", "TN": "#D2B48C", "BG": "#E8DCC0",
    ]

    /// Every colour code in the order a picker should offer them.
    public static let colorOrder = ["BK", "BN", "RD", "OG", "YE", "GN", "LG", "DG", "BU", "LB", "DB", "VT", "GY", "WH",
                                    "PK", "TQ", "TN", "BG", "GD", "SR"]

    public static let colorTitles: [String: String] = [
        "BK": "Black", "BN": "Brown", "RD": "Red", "OG": "Orange", "YE": "Yellow", "GN": "Green", "LG": "Light green",
        "DG": "Dark green", "BU": "Blue", "LB": "Light blue", "DB": "Dark blue", "VT": "Violet", "GY": "Grey", "WH": "White",
        "PK": "Pink", "TQ": "Turquoise", "TN": "Tan", "BG": "Beige", "GD": "Gold", "SR": "Silver",
    ]

    public static func defaultOD(for size: WireSize, insulation: String) -> Double {
        let base: Double
        if let awg = size.awg, let od = txlODByAWG[awg] {
            base = od
        } else {
            // Conductor diameter from area, plus a thin-wall insulation thickness.
            base = 2 * (size.crossSectionMM2 / .pi).squareRoot() + 0.5
        }
        switch insulation.uppercased() {
        case "GXL": return base + 0.15
        case "SXL": return base + 0.35
        default: return base
        }
    }
}
