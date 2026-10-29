import os

/// Intervals for Instruments' Points of Interest track: harness analysis, drawing and PDF generation.
/// Product ▸ Profile in Xcode, then the Points of Interest instrument, shows how long each took.
public enum Signposts {
    public static let signposter = OSSignposter(subsystem: "com.loomo.Loomo", category: .pointsOfInterest)

    @inlinable
    public static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try body()
    }
}
