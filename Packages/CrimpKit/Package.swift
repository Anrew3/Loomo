// swift-tools-version: 6.2
import PackageDescription

// CrimpKit: everything in Loomo that isn't the Mac app's UI. The app (Loomo.xcodeproj)
// links these libraries; the `crimp` command-line tool and the tests live here too.
let package = Package(
    name: "CrimpKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CrimpCore", targets: ["CrimpCore"]),
        .library(name: "CrimpOutputs", targets: ["CrimpOutputs"]),
        .library(name: "PartsClient", targets: ["PartsClient"]),
        .executable(name: "crimp", targets: ["CrimpCLI"]),
    ],
    targets: [
        // Model, routing, lengths, BOM, rules, import/export. Foundation only.
        .target(name: "CrimpCore"),
        // CoreGraphics renderer and PDF drawing set, shared by the canvas and exports.
        .target(name: "CrimpOutputs", dependencies: ["CrimpCore"]),
        .target(name: "PartsClient", dependencies: ["CrimpCore"]),
        // `crimp`: command-line editing and checking of .loomo files (for scripts and MCP servers).
        .executableTarget(name: "CrimpCLI", dependencies: ["CrimpCore", "CrimpOutputs", "PartsClient"]),
        .testTarget(name: "CrimpCoreTests", dependencies: ["CrimpCore", "CrimpOutputs", "PartsClient"],
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
