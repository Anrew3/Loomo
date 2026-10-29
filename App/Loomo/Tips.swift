import CrimpCore
import SwiftUI
import TipKit

// One-time tips for things that are easy to miss. Each appears when it becomes useful and is dismissed
// for good once the user does the thing (or closes the tip). Help ▸ Show Tips Again brings them back.

struct InsertTip: Tip {
    var title: Text { Text("Add anything from the drawing") }
    var message: Text? {
        Text("Right-click the drawing, or press a key where the pointer is: C connector, S splice, W wire, B bundle. Press ? for every shortcut.")
    }
    var image: Image? { Image(systemName: "cursorarrow.click.2") }
}

struct BundleTip: Tip {
    /// Things on the drawing; the tip needs two to be useful.
    @Parameter static var nodeCount: Int = 0
    var title: Text { Text("Connect with a bundle") }
    var message: Text? { Text("Hold ⌥ and drag from one connector or splice to another to draw the bundle between them.") }
    var image: Image? { Image(systemName: "line.diagonal") }
    var rules: [Rule] { [#Rule(Self.$nodeCount) { $0 >= 2 }] }
}

struct PhotoTip: Tip {
    @Parameter static var hasConnectorPhoto: Bool = false
    var title: Text { Text("Move a part photo") }
    var message: Text? {
        Text("Right-click a connector and choose Unlock Photo & Label, then drag the photo anywhere. Its label moves with it.")
    }
    var image: Image? { Image(systemName: "photo.on.rectangle") }
    var rules: [Rule] { [#Rule(Self.$hasConnectorPhoto) { $0 }] }
}

struct AssistantTip: Tip {
    @Parameter static var available: Bool = false
    var title: Text { Text("Ask the assistant") }
    var message: Text? {
        Text("Describe a change (\"add a DT06-2S and wire cavity 1 to SP1\") or ask why a rule check failed. It runs on this Mac.")
    }
    var image: Image? { Image(systemName: "sparkles") }
    var rules: [Rule] { [#Rule(Self.$available) { $0 }] }
}

enum CrimpTips {
    /// Call once at launch.
    static func configure() {
        if UserDefaults.standard.bool(forKey: "tips.resetOnLaunch") {
            UserDefaults.standard.removeObject(forKey: "tips.resetOnLaunch")
            try? Tips.resetDatastore()
        }
        if ProcessInfo.processInfo.arguments.contains("-UITests") { Tips.hideAllTipsForTesting() }
        try? Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.applicationDefault)])
    }

    /// Updates what the rules know about the open harness.
    static func observe(_ h: Harness, photo: (PartRef) -> URL?) {
        BundleTip.nodeCount = h.nodes.count
        PhotoTip.hasConnectorPhoto = h.connectors.contains { c in !c.kind.isLooseTerminal && c.part.flatMap(photo) != nil }
    }
}
