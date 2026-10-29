import SwiftUI

/// Reference card for every shortcut; opened with ? on the drawing, ⌘/ or Help ▸ Keyboard Shortcuts.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("Insert at the pointer (when the drawing has focus; also right-click and the Insert menu)", [
            ("C", "Component: connector, fuse holder, relay, terminal… (type from the part data)"), ("M", "In-line mated pair"),
            ("S", "Splice (on a bundle: splits it)"), ("J", "Breakout (on a bundle: splits it)"), ("K", "Clip (on a bundle: splits it)"),
            ("W", "New wire (from the selected connector or splice)"), ("B", "Bundle between the two selected nodes"),
            ("L", "Bundle label"), ("N", "Sticky note"), ("G", "Frame"), ("T", "Text"), ("A", "Arrow"), ("X", "Box"), ("I", "Image"),
        ]),
        ("Selection and editing", [
            ("Click / ⇧-click", "Select / add to selection"), ("Drag empty space", "Box-select"),
            ("Drag a selected item", "Move the whole selection"), ("⌥-drag node to node", "Connect them with a bundle"),
            ("Right-click", "Add things, or options for whatever is under the pointer"),
            ("⌘A", "Select all"), ("⌫ / Delete", "Delete selection"), ("⌘D", "Duplicate selection"),
            ("⌘C / ⌘X / ⌘V", "Copy / cut / paste harness sections"), ("← → ↑ ↓", "Nudge 1 pt (⇧ for a larger step)"),
            ("Return / double-click", "Open the selected connector's pinout"), ("Esc", "Clear selection"),
        ]),
        ("View", [("F", "Zoom to fit"), ("⌘= / ⌘−", "Zoom in / out"), ("⌘0", "Actual size"), ("?", "This sheet")]),
        ("Documents", [
            ("⌘N", "New harness"), ("⇧⌘N", "New system project"),
            ("⌥⇧⌘N", "New from sample system"), ("⌘Z / ⇧⌘Z", "Undo / redo"), ("⌘E", "Export drawing set PDF"),
            ("⇧⌘E", "Export Excel workbook"), ("⌥⌘W", "New wire…"), ("⇧⌘L", "Parts library"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(systemName: "keyboard", tint: Pane.drawing.tint, size: 34)
                Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.0) { title, rows in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(.headline)
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                                ForEach(rows, id: \.0) { key, what in
                                    GridRow {
                                        Text(key).font(.system(.body, design: .rounded).bold())
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                        Text(what)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(width: 560, height: 620)
    }
}

/// Shows the shortcuts sheet when the drawing (or the Help menu) asks for it.
struct ShortcutsSheetHost: ViewModifier {
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $show) { ShortcutsSheet() }
            .onReceive(NotificationCenter.default.publisher(for: .showShortcuts)) { _ in
                if NSApp.keyWindow?.isKeyWindow == true { show = true }
            }
    }
}
