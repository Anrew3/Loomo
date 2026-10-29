import AppKit
import SwiftUI

/// Builds an NSMenu whose items run closures.
final class MenuBuilder {
    let menu = NSMenu()

    init() {
        menu.autoenablesItems = false
        // No "Ask Siri"/Services items: these menus are about the drawing, not text.
        menu.allowsContextMenuPlugIns = false
    }

    @discardableResult
    func item(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], image: String? = nil,
              enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = modifiers
        item.isEnabled = enabled
        if let image { item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
        menu.addItem(item)
        return item
    }

    func submenu(_ title: String, image: String? = nil, _ build: (MenuBuilder) -> Void) {
        let sub = MenuBuilder()
        build(sub)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let image { item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
        item.submenu = sub.menu
        menu.addItem(item)
    }

    func header(_ title: String) {
        if #available(macOS 14.0, *) { menu.addItem(.sectionHeader(title: title)) }
    }

    func separator() {
        if !(menu.items.last?.isSeparatorItem ?? true) { menu.addItem(.separator()) }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// Transparent overlay that shows a context menu for right-clicks (and control-clicks) at the click point.
/// Every other mouse event falls through to the SwiftUI view underneath.
struct RightClickMenu: NSViewRepresentable {
    /// Point is in the overlay's own coordinates (top-left origin).
    let menu: (CGPoint) -> NSMenu?

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.provider = menu
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.provider = menu }

    final class CatcherView: NSView {
        var provider: ((CGPoint) -> NSMenu?)?
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let isContextClick = e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return isContextClick ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { show(event) }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { show(event) } else { super.mouseDown(with: event) }
        }

        private func show(_ event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            guard let menu = provider?(p), !menu.items.isEmpty else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
