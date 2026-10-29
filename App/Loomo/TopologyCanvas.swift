import AppKit
import CrimpCore
import CrimpOutputs
import SwiftUI
import TipKit
import UniformTypeIdentifiers

/// The harness drawing editor. Drawing is done by `HarnessRenderer`, the same code the PDF export uses.
///
/// The mouse always does the same thing: click selects, ⇧-click adds, drag on empty space box-selects,
/// drag a selected item moves the selection, ⌥-drag from one node to another draws a bundle.
/// Everything is added with right-click, the Insert menu, or a single key that inserts at the pointer.
struct TopologyCanvas: View {
    private enum DragMode {
        case move(origins: [EntityID: Point2D], nodes: Set<EntityID>, annotations: Set<EntityID>, anchor: EntityID)
        case marquee(start: CGPoint, additive: Bool)
        case bundle(from: EntityID)
        /// Dragging an unlocked connector's photo and text away from its dot.
        case tag(connector: EntityID, origin: Point2D)
        /// Dragging a connection table away from its connector or splice.
        case table(id: EntityID, origin: Point2D)
        case none
    }

    @ObservedObject var doc: HarnessDocument
    var jump: ((Pane) -> Void)? = nil
    @State private var zoom: CGFloat = 1
    @AppStorage("canvas.rulers") private var showRulers = false
    @State private var drag: DragMode?
    /// Start point of the gesture `drag` belongs to; a different one means a new gesture.
    @State private var dragStart: CGPoint?
    @State private var marquee: CGRect?
    @State private var rubberBand: (CGPoint, CGPoint)?
    /// Alignment guides shown while dragging: the x and/or y the dragged item snapped to.
    @State private var guides: (x: CGFloat?, y: CGFloat?) = (nil, nil)
    @State private var viewport: CGSize = .zero
    @State private var scroll = ScrollPosition()
    /// Set once the drawing has been fitted and centred after the document opened.
    @State private var centered = false
    /// The drawing's view inside the scroll view, for measuring what the side columns cover.
    @State private var anchor = CanvasAnchor()
    /// Set when the zoom was changed by hand; the drawing then stops re-fitting itself when the side columns change.
    @State private var userZoomed = false
    @FocusState private var focused: Bool

    var body: some View {
        let h = doc.harness
        var options = HarnessRenderer.Options()
        options.selectedIDs = doc.selectedIDs
        if case let .bundle(from)? = drag { options.selectedIDs.insert(from) }
        if case let .wire(w)? = doc.selection { options.highlightWireIDs = [w] }
        if case let .cable(c)? = doc.selection { options.highlightWireIDs = Set(h.wires.filter { $0.cableID == c }.map(\.id)) }
        if case let .twist(t)? = doc.selection { options.highlightWireIDs = Set(h.twists.first { $0.id == t }?.wireIDs ?? []) }
        options.ink = NSColor.labelColor.cgColor
        options.secondaryInk = NSColor.secondaryLabelColor.cgColor
        options.accent = NSColor.controlAccentColor.cgColor
        options.paper = NSColor.textBackgroundColor.cgColor
        options.bundleFill = Self.tubeFill.cgColor
        options.bundleEdge = Self.tubeEdge.cgColor
        options.tableHeader = NSColor.quaternaryLabelColor.blended(withFraction: 0.5, of: .textBackgroundColor)?.cgColor ?? options.tableHeader
        options.tableGrid = NSColor.separatorColor.cgColor
        options.marquee = marquee
        options.photoURL = { LibraryStore.shared.photoURL(for: $0) }
        options.showUnlockedTags = true
        let renderer = HarnessRenderer(harness: h, analysis: doc.analysis, options: options)
        let b = renderer.bounds
        // Room to scroll the drawing to the middle of the window, whatever its size.
        let contentSize = CGSize(width: max(max(b.maxX + 400, 1400) * zoom, b.midX * zoom + viewport.width),
                                 height: max(max(b.maxY + 400, 900) * zoom, b.midY * zoom + viewport.height))

        return ZStack {
            AmbientBackground(canvas: true)
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    Canvas { ctx, size in
                        drawGrid(ctx, size)
                        drawRulers(ctx, size)
                        ctx.withCGContext { cg in
                            cg.scaleBy(x: zoom, y: zoom)
                            renderer.draw(in: cg)
                            if guides.x != nil || guides.y != nil {
                                cg.setStrokeColor(NSColor.systemPink.cgColor)
                                cg.setLineWidth(1 / zoom)
                                cg.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom])
                                let far = size.width / zoom + size.height / zoom
                                if let x = guides.x { cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: far)) }
                                if let y = guides.y { cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: far, y: y)) }
                                cg.strokePath()
                                cg.setLineDash(phase: 0, lengths: [])
                            }
                            if let (a, z) = rubberBand {
                                cg.setStrokeColor(NSColor.controlAccentColor.cgColor)
                                cg.setLineWidth(2)
                                cg.setLineDash(phase: 0, lengths: [5, 3])
                                cg.move(to: a)
                                cg.addLine(to: z)
                                cg.strokePath()
                            }
                        }
                    }
                    .frame(width: contentSize.width, height: contentSize.height)
                    .background(CanvasAnchorView(anchor: anchor))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged(dragChanged).onEnded(dragEnded))
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        if case let .active(p) = phase { doc.lastPointer = model(p) }
                    }
                    .overlay(RightClickMenu { contextMenu(at: model($0), renderer: renderer) })
                }
                .contentMargins(.top, 64, for: .scrollContent)
                .contentMargins(.bottom, 52, for: .scrollContent)
                .scrollIndicators(.automatic)
                .scrollPosition($scroll)
                .onAppear { viewport = geo.size }
                .onChange(of: geo.size) { viewport = geo.size }
                // Open with the whole harness fitted and in the middle of the window, once the window has its size.
                .task {
                    guard !centered else { return }
                    for _ in 0..<20 where viewport.width < 300 { try? await Task.sleep(for: .milliseconds(50)) }
                    try? await Task.sleep(for: .milliseconds(150))
                    centered = true
                    zoomToFit(hitRenderer)
                }
                // Opening or closing the sidebar or inspector changes what's visible: fit again (unless zoomed by hand).
                .onReceive(NotificationCenter.default.publisher(for: NSSplitView.didResizeSubviewsNotification)) { note in
                    guard !userZoomed, centered, let split = note.object as? NSView, split.window === anchor.view?.window else { return }
                    anchor.refit?.cancel()
                    let work = DispatchWorkItem { zoomToFit(hitRenderer, user: false) }
                    anchor.refit = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .down) { handleKey($0, renderer) }
            .onDeleteCommand { doc.deleteItems(doc.selectedIDs) }
            .onCopyCommand { copyProviders() }
            .onCutCommand {
                let p = copyProviders()
                doc.deleteItems(doc.selectedIDs)
                return p
            }
            .onPasteCommand(of: [.loomoClip]) { _ in doc.paste() }
            .onCommand(#selector(NSResponder.selectAll(_:))) { doc.selectAll() }
        }
        .overlay(alignment: .top) { viewBar(renderer).padding(.top, 12) }
        .overlay(alignment: .topLeading) {
            // Contextual tips, under the floating controls.
            VStack(alignment: .leading, spacing: 8) {
                TipView(BundleTip())
                TipView(PhotoTip())
            }
            .frame(maxWidth: 340)
            .padding(.top, 60)
            .padding(.leading, 16)
        }
        .onAppear { CrimpTips.observe(doc.harness, photo: LibraryStore.shared.photoURL) }
        // Fetch part photos the drawing needs that aren't on disk yet (a file opened on this Mac for the first time).
        .task(id: doc.harness.connectors.compactMap(\.part?.imageURL)) { await loadMissingPhotos() }
        .onChange(of: doc.harness) { CrimpTips.observe(doc.harness, photo: LibraryStore.shared.photoURL) }
        .overlay(alignment: .bottom) { statusBar.padding(.horizontal, 16).padding(.bottom, 12) }
        .sheet(item: $doc.placement) { placement in
            PlacePartSheet(doc: doc, placement: placement)
        }
        .onAppear { focused = true }
    }

    private func loadMissingPhotos() async {
        let urls = Set(doc.harness.connectors.compactMap { $0.part.flatMap(LibraryStore.shared.photoURL) })
            .filter { PartImageCache.shared.cached($0) == nil }
        guard !urls.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for url in urls { group.addTask { _ = await PartImageCache.shared.image(for: url) } }
        }
        doc.objectWillChange.send()     // redraw with the photos
    }

    /// Bundle tube colours for the light and dark appearance.
    static let tubeFill = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 0.36, alpha: 1) : NSColor(white: 0.86, alpha: 1) }
    static let tubeEdge = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 0.66, alpha: 1) : NSColor(white: 0.45, alpha: 1) }

    // MARK: View bar and status

    /// Floating glass controls. View settings only; nothing here changes what the mouse does.
    private func viewBar(_ renderer: HarnessRenderer) -> some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(InsertKind.allCases) { k in
                        Button { doc.insert(k) } label: { Label("\(k.title)  (\(String(k.key).uppercased()))", systemImage: k.icon) }
                    }
                } label: {
                    Label("Insert", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .glassEffect(.regular.tint(.accentColor).interactive(), in: Capsule())
                .help("Everything here is also on right-click, in the Insert menu, and on single keys")
                .popoverTip(InsertTip(), arrowEdge: .top)

                HStack(spacing: 2) {
                    chip("Photos", icon: "photo", isOn: Binding(get: { doc.harness.settings.showPartPhotos ?? true },
                                                                set: { doc.harness.settings.showPartPhotos = $0 }))
                    chip("Snap", icon: "square.grid.3x3", isOn: $doc.harness.settings.snapToGrid)
                    chip("Rulers", icon: "ruler", isOn: $showRulers)
                        .help("Rulers along the edges, in the harness's units (true at To Scale)")
                    chip("Tables", icon: "tablecells", isOn: Binding(get: { doc.harness.settings.showConnectionTables ?? false },
                                                                    set: { doc.harness.settings.showConnectionTables = $0 }))
                        .help("Show each connector's and splice's connection table on the drawing")
                    chip("Items", icon: "number", isOn: Binding(get: { doc.harness.settings.showItemNumbers ?? false },
                                                               set: { doc.harness.settings.showItemNumbers = $0 }))
                        .help("Show BOM item numbers beside parts on the drawing")
                    Button { doc.perform("Lay Out to Scale") { $0.layoutToScale(pointsPerMM: 0.5) } } label: {
                        Label("To Scale", systemImage: "ruler").padding(.horizontal, 10).padding(.vertical, 6).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Redraw every segment at its true length (1 mm = 0.5 pt)")
                }
                .padding(3)
                .glassEffect(.regular, in: Capsule())

                HStack(spacing: 0) {
                    Button { zoom = max(0.25, zoom / 1.25); userZoomed = true } label: { Image(systemName: "minus").frame(width: 28, height: 26).contentShape(Rectangle()) }
                        .help("Zoom out (⌘−)")
                    Button { zoomToFit(renderer) } label: {
                        Text("\(Int(zoom * 100))%").monospacedDigit().frame(minWidth: 46).frame(height: 26).contentShape(Rectangle())
                    }
                    .help("Zoom to fit (F)")
                    Button { zoom = min(4, zoom * 1.25); userZoomed = true } label: { Image(systemName: "plus").frame(width: 28, height: 26).contentShape(Rectangle()) }
                        .help("Zoom in (⌘=)")
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .glassEffect(.regular, in: Capsule())
            }
        }
    }

    /// A capsule toggle that lights up in the accent colour when on.
    private func chip(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Label(title, systemImage: icon)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : .secondary)
                .background(Capsule().fill(isOn.wrappedValue ? Color.accentColor.opacity(0.18) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isOn.wrappedValue)
    }

    private var statusBar: some View {
        let h = doc.harness
        let n = doc.selectionCount
        let bundling: Bool = { if case .bundle? = drag { return true } else { return false } }()
        let tagging: Bool = { if case .tag? = drag { return true } else { return false } }()
        let movingTable: Bool = { if case .table? = drag { return true } else { return false } }()
        return HStack(spacing: 14) {
            Image(systemName: bundling ? "line.diagonal" : "cursorarrow.rays").foregroundStyle(Color.accentColor)
            Text(bundling ? "Release over another node to connect them with a bundle."
                 : tagging ? "Moving the photo and label; right-click ▸ Lock Photo & Label to fix them in place."
                 : movingTable ? "Moving the connection table; right-click ▸ Reset Table Position puts it back." : hint)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if n > 1 {
                Text("\(n) selected").fontWeight(.semibold).foregroundStyle(Color.accentColor)
            }
            stat("powerplug", h.connectors.count)
            stat("line.diagonal", h.wires.count)
            stat("point.3.connected.trianglepath.dotted", h.segments.count)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .frame(maxWidth: 980)
    }

    private func stat(_ icon: String, _ n: Int) -> some View {
        Label("\(n)", systemImage: icon).monospacedDigit().labelStyle(.titleAndIcon)
    }

    private var hint: String {
        "Right-click to add · click selects · drag moves · ⌥-drag node to node draws a bundle · C connector, W wire, S splice · ? all shortcuts"
    }

    // MARK: Gestures

    private func model(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / zoom, y: p.y / zoom) }

    private func dragChanged(_ v: DragGesture.Value) {
        focused = true
        // A gesture can end without onEnded (a menu or window change cancels it); never let a new
        // gesture continue the old one.
        if dragStart != v.startLocation {
            drag = nil
            marquee = nil
            rubberBand = nil
            dragStart = v.startLocation
        }
        let start = model(v.startLocation)
        if drag == nil {
            drag = DragMode.none
            let shift = NSEvent.modifierFlags.contains(.shift)
            let option = NSEvent.modifierFlags.contains(.option)
            if option, let n = hitNode(start) {
                drag = .bundle(from: n)
            } else if hitNode(start) == nil, let t = hitTable(start) {
                selectOwner(ofTable: t)
                drag = .table(id: t, origin: currentTableOffset(t))
            } else if let (c, nodeID) = hitUnlockedTag(start) {
                if !doc.selectedNodeIDs.contains(nodeID) { select(nodeID, additive: shift) }
                drag = .tag(connector: c.id, origin: c.tagOffset ?? Point2D(0, 0))
            } else if let n = hitNode(start) ?? hitAnnotation(start) {
                let alreadySelected = doc.selectedIDs.contains(n) || doc.selectedNodeIDs.contains(n)
                if !alreadySelected { select(n, additive: shift) }
                var nodes = doc.selectedNodeIDs
                var anns = Set(doc.selectedIDs.filter { id in doc.harness.annotations.contains { $0.id == id } })
                if doc.harness.node(n) != nil { nodes.insert(n) } else { anns.insert(n) }
                var origins: [EntityID: Point2D] = [:]
                for node in doc.harness.nodes where nodes.contains(node.id) { origins[node.id] = node.position }
                for a in doc.harness.annotations where anns.contains(a.id) { origins[a.id] = Point2D(a.x, a.y) }
                drag = .move(origins: origins, nodes: nodes, annotations: anns, anchor: n)
            } else if hitLabel(start) == nil && doc.segment(near: start) == nil {
                drag = .marquee(start: start, additive: shift)
            }
        }
        guard hypot(v.translation.width, v.translation.height) > 3 else { return }
        switch drag {
        case let .move(origins, nodes, anns, anchor)?:
            var dx = v.translation.width / zoom, dy = v.translation.height / zoom
            if doc.harness.settings.snapToGrid, let o = origins[anchor] {
                let g = max(doc.harness.settings.gridSize, 1)
                dx = ((o.x + dx) / g).rounded() * g - o.x
                dy = ((o.y + dy) / g).rounded() * g - o.y
            }
            // Smart guides: line the dragged node up with any other node that is within a few points of it.
            guides = (nil, nil)
            if let o = origins[anchor], doc.harness.node(anchor) != nil {
                let tolerance = 6 / zoom
                let others = doc.harness.nodes.filter { !nodes.contains($0.id) }
                let px = o.x + dx, py = o.y + dy
                if let m = others.min(by: { abs($0.position.x - px) < abs($1.position.x - px) }), abs(m.position.x - px) < tolerance {
                    dx = m.position.x - o.x; guides.x = m.position.x
                }
                if let m = others.min(by: { abs($0.position.y - py) < abs($1.position.y - py) }), abs(m.position.y - py) < tolerance {
                    dy = m.position.y - o.y; guides.y = m.position.y
                }
            }
            doc.harness.move(nodes: nodes, annotations: anns, from: origins, by: dx, dy)
        case let .marquee(start, _)?:
            let p = model(v.location)
            marquee = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        case let .bundle(from)?:
            if let a = doc.harness.node(from)?.position { rubberBand = (CGPoint(x: a.x, y: a.y), model(v.location)) }
        case let .table(id, origin)?:
            let off = Point2D((origin.x + v.translation.width / zoom).rounded(), (origin.y + v.translation.height / zoom).rounded())
            if let i = doc.harness.connectors.firstIndex(where: { $0.id == id }) { doc.harness.connectors[i].tableOffset = off }
            if let i = doc.harness.splices.firstIndex(where: { $0.id == id }) { doc.harness.splices[i].tableOffset = off }
        case let .tag(cid, origin)?:
            if let i = doc.harness.connectors.firstIndex(where: { $0.id == cid }) {
                doc.harness.connectors[i].tagOffset = Point2D((origin.x + v.translation.width / zoom).rounded(),
                                                              (origin.y + v.translation.height / zoom).rounded())
            }
        default:
            break
        }
    }

    private func dragEnded(_ v: DragGesture.Value) {
        defer { drag = nil; dragStart = nil; marquee = nil; rubberBand = nil; guides = (nil, nil) }
        let moved = hypot(v.translation.width, v.translation.height) > 3
        if case let .bundle(from)? = drag {
            if moved, let to = hitNode(model(v.location)), to != from {
                doc.addSegment(from, to)
                BundleTip().invalidate(reason: .actionPerformed)
            }
            return
        }
        if case .tag? = drag, moved { return }
        if case .table? = drag { return }
        if case let .marquee(_, additive)? = drag, moved, let r = marquee {
            let nodes = doc.harness.nodes.filter { r.contains(CGPoint(x: $0.position.x, y: $0.position.y)) }.map(\.id)
            let anns = doc.harness.annotations.filter { r.intersects(CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).standardized) }.map(\.id)
            doc.multiSelection = (additive ? doc.multiSelection : []).union(nodes).union(anns)
            if doc.multiSelection.count == 1, let only = doc.multiSelection.first {
                doc.selection = doc.harness.node(only) != nil ? doc.selection(forNode: only) : .annotation(only)
            } else {
                doc.selection = nil
            }
            return
        }
        guard !moved else { return }
        click(at: model(v.location))
    }

    private func select(_ id: EntityID, additive: Bool) {
        if additive {
            if doc.multiSelection.contains(id) { doc.multiSelection.remove(id) } else { doc.multiSelection.insert(id) }
            if let s = doc.selection, doc.harness.node(s.id) == nil, doc.harness.connector(s.id) == nil, doc.harness.splice(s.id) == nil {
                doc.selection = nil
            }
        } else {
            doc.multiSelection = [id]
            doc.selection = doc.harness.node(id) != nil ? doc.selection(forNode: id) : .annotation(id)
        }
    }

    /// A plain click only ever selects.
    private func click(at p: CGPoint) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        let doubleClick = (NSApp.currentEvent?.clickCount ?? 1) >= 2
        if let n = hitNode(p) {
            select(n, additive: shift)
            if doubleClick, case .connector? = doc.selection { jump?(.connectors) }
        } else if let a = hitAnnotation(p) {
            select(a, additive: shift)
        } else if let l = hitLabel(p) {
            doc.selection = .label(l)
            doc.multiSelection = shift ? doc.multiSelection.union([l]) : [l]
        } else if let s = doc.segment(near: p)?.0 {
            doc.selection = .segment(s)
            doc.multiSelection = shift ? doc.multiSelection.union([s]) : []
        } else if !shift {
            doc.selection = nil
            doc.multiSelection = []
        }
    }

    /// Fits the whole drawing into the part of the window you can see (between the sidebar and the inspector,
    /// below the toolbar and the floating bars) and centres it there.
    private func zoomToFit(_ renderer: HarnessRenderer, user: Bool = true) {
        if user { userZoomed = false }
        let b = renderer.bounds
        guard b.width > 0 else { zoom = 1; return }
        // The floating view bar covers the top 64 points and the status bar the bottom 52.
        let bars = (top: CGFloat(64), bottom: CGFloat(52))
        // The window-based measure is only right when the sidebar and inspector float over the canvas. Where they
        // sit beside it instead, it comes out as the whole window: then the canvas's own size is the truth.
        guard let visible = anchor.visibleRect(), visible.width > 100, viewport.width == 0 || visible.width <= viewport.width + 1 else {
            guard viewport.width > 0 else { zoom = 1; return }
            let size = CGSize(width: viewport.width, height: max(200, viewport.height - bars.top - bars.bottom))
            let z = max(0.25, min(2, min(size.width / (b.width + 80), size.height / (b.height + 80))))
            zoom = z
            let target = CGPoint(x: max(0, b.midX * z - size.width / 2), y: max(0, b.midY * z - size.height / 2))
            DispatchQueue.main.async { scroll.scrollTo(point: target) }
            return
        }
        let area = CGRect(x: visible.minX, y: visible.minY + bars.bottom, width: visible.width,
                          height: max(150, visible.height - bars.top - bars.bottom))      // window coordinates: y up
        let z = max(0.25, min(2, min(area.width / (b.width + 80), area.height / (b.height + 80))))
        zoom = z
        // After the content has been laid out at the new zoom, scroll the drawing's centre to the area's centre.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            anchor.scroll(canvasPoint: CGPoint(x: b.midX * z, y: b.midY * z), toWindowPoint: CGPoint(x: area.midX, y: area.midY))
        }
    }

    // MARK: Connection tables

    /// The renderer as the canvas draws it, for hit-testing tables.
    private var hitRenderer: HarnessRenderer {
        var o = HarnessRenderer.Options()
        o.photoURL = { LibraryStore.shared.photoURL(for: $0) }
        return HarnessRenderer(harness: doc.harness, analysis: doc.analysis, options: o)
    }

    private func hitTable(_ p: CGPoint) -> EntityID? {
        guard doc.harness.settings.showConnectionTables == true else { return nil }
        let r = hitRenderer
        return (doc.harness.connectors.map(\.id) + doc.harness.splices.map(\.id)).reversed().first { r.tableFrame(for: $0)?.contains(p) == true }
    }

    private func currentTableOffset(_ id: EntityID) -> Point2D {
        let r = hitRenderer
        guard let f = r.tableFrame(for: id), let base = r.tableBase(for: id) else { return Point2D(0, 0) }
        return Point2D(f.minX - base.minX, f.minY - base.minY)
    }

    private func selectOwner(ofTable id: EntityID) {
        if let n = doc.harness.connector(id)?.nodeID ?? doc.harness.splice(id)?.nodeID { select(n, additive: false) }
    }

    // MARK: Keyboard (one-shot: each key acts once at the pointer; there are no modes)

    private func handleKey(_ press: KeyPress, _ renderer: HarnessRenderer) -> KeyPress.Result {
        let cmd = press.modifiers.contains(.command)
        let step: Double = press.modifiers.contains(.shift) ? max(doc.harness.settings.gridSize, 1) * 5 : 1
        switch press.key {
        case .escape:
            doc.selection = nil
            doc.multiSelection = []
            return .handled
        case .leftArrow: doc.nudge(-step, 0); return .handled
        case .rightArrow: doc.nudge(step, 0); return .handled
        case .upArrow: doc.nudge(0, -step); return .handled
        case .downArrow: doc.nudge(0, step); return .handled
        case .return:
            if case .connector? = doc.selection { jump?(.connectors); return .handled }
            return .ignored
        default: break
        }
        guard let c = press.characters.lowercased().first else { return .ignored }
        if cmd {
            switch c {
            case "d": doc.duplicateSelection(); return .handled
            case "=", "+": zoom = min(4, zoom * 1.25); userZoomed = true; return .handled
            case "-": zoom = max(0.25, zoom / 1.25); userZoomed = true; return .handled
            case "0": zoom = 1; userZoomed = true; return .handled
            default: return .ignored
            }
        }
        guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        if let kind = InsertKind.allCases.first(where: { $0.key == c }) {
            doc.insert(kind)
            return .handled
        }
        switch c {
        case "f": zoomToFit(renderer); return .handled
        case "?", "/": NotificationCenter.default.post(name: .showShortcuts, object: nil); return .handled
        default: return .ignored
        }
    }

    private func copyProviders() -> [NSItemProvider] {
        doc.copy()
        guard let data = NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(HarnessClip.pasteboardType)) else { return [] }
        return [NSItemProvider(item: data as NSData, typeIdentifier: HarnessClip.pasteboardType)]
    }

    // MARK: Context menus

    private func contextMenu(at p: CGPoint, renderer: HarnessRenderer) -> NSMenu? {
        let m = MenuBuilder()
        let h = doc.harness
        doc.lastPointer = p
        let hitT = hitNode(p) == nil ? hitTable(p) : nil
        let hitN = hitNode(p) ?? hitT.flatMap { doc.harness.connector($0)?.nodeID ?? doc.harness.splice($0)?.nodeID }
        let hitA = hitAnnotation(p), hitL = hitLabel(p), hitS = doc.segment(near: p)
        let hitID = hitN ?? hitA ?? hitL ?? hitS?.0
        // Right-clicking something outside the selection selects it first, like Finder.
        if let id = hitID, !doc.selectedIDs.contains(id), !doc.selectedNodeIDs.contains(id) {
            if let n = hitN { select(n, additive: false) }
            else if let a = hitA { select(a, additive: false) }
            else if let l = hitL { doc.selection = .label(l); doc.multiSelection = [l] }
            else if let s = hitS?.0 { doc.selection = .segment(s); doc.multiSelection = [] }
        }
        let count = doc.selectedNodeIDs.count + doc.selectedIDs.filter { id in h.annotations.contains { $0.id == id } }.count

        if hitID != nil, count > 1 {
            m.header("\(count) items selected")
            let ends = doc.selectedEnds
            if ends.count == 2 {
                m.item("Wire Between \(ends[0]) and \(ends[1])…", key: "w", image: "cable.connector.horizontal") { doc.requestWire(from: ends[0], to: ends[1]) }
            }
            if doc.selectedNodeIDs.count == 2 {
                m.item("Connect with Bundle", key: "b", image: "line.diagonal") { doc.insert(.bundle) }
            }
            let pair = ends.filter { h.connector($0) != nil }
            if pair.count == 2 {
                m.item("Pass-Through Wires \(pair[0]) ↔ \(pair[1])…", image: "arrow.left.arrow.right") { doc.requestPassThrough(pair[0], pair[1]) }
                m.item("Mate \(pair[0]) with \(pair[1]) In Line", image: "link") {
                    doc.perform("Mate \(pair[0]) and \(pair[1])") { $0.setMate(pair[0], pair[1]) }
                }
            }
            m.item("Duplicate", key: "d", modifiers: .command, image: "plus.square.on.square") { doc.duplicateSelection() }
            m.item("Copy", key: "c", modifiers: .command, image: "doc.on.doc") { doc.copy() }
            m.submenu("Align", image: "align.horizontal.center") { a in
                a.item("Align Horizontally") { doc.align(.horizontal) }
                a.item("Align Vertically") { doc.align(.vertical) }
            }
            m.separator()
            m.item("Delete \(count) Items", key: "\u{8}", image: "trash") { doc.deleteItems(doc.selectedIDs) }
            return m.menu
        }

        if let n = hitN, let node = h.node(n) {
            if let c = h.connectors.first(where: { $0.nodeID == n }) {
                m.header([c.id, c.name, c.part?.mpn].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                m.item("Edit Pinout…", key: "\r", image: "square.grid.3x3") { doc.selection = .connector(c.id); jump?(.connectors) }
                m.item(c.part == nil ? "Choose Part…" : "Change Part…", image: "magnifyingglass") { doc.placement = .init(mode: .replacePart(c.id)) }
                if let url = c.part?.datasheetURL { m.item("Open Datasheet", image: "doc.text") { NSWorkspace.shared.open(url) } }
                let unlocked = c.tagUnlocked == true
                m.item(unlocked ? "Lock Photo & Label" : "Unlock Photo & Label to Move", image: unlocked ? "lock" : "lock.open") {
                    doc.perform(unlocked ? "Lock Photo & Label" : "Unlock Photo & Label") { h in
                        if let i = h.connectors.firstIndex(where: { $0.id == c.id }) { h.connectors[i].tagUnlocked = unlocked ? nil : true }
                        PhotoTip().invalidate(reason: .actionPerformed)
                    }
                }
                if c.tagOffset != nil {
                    m.item("Reset Photo & Label Position", image: "arrow.uturn.backward") {
                        doc.perform("Reset Photo & Label") { h in
                            if let i = h.connectors.firstIndex(where: { $0.id == c.id }) { h.connectors[i].tagOffset = nil }
                        }
                    }
                }
                if c.tableOffset != nil {
                    m.item("Reset Table Position", image: "tablecells") {
                        doc.perform("Reset Table Position") { h in
                            if let i = h.connectors.firstIndex(where: { $0.id == c.id }) { h.connectors[i].tableOffset = nil }
                        }
                    }
                }
                m.item("Change Picture…", image: "photo") { doc.chooseConnectorPicture(c.id) }
                m.item("Remap Connections to Another Connector…", image: "arrow.right.arrow.left") { doc.remap = RemapRequest(from: c.id) }
                if c.imagePNG != nil {
                    m.item("Crop Picture…", image: "crop") { doc.cropTarget = CropTarget(connectorID: c.id) }
                    m.item("Use Part Photo", image: "arrow.uturn.backward") {
                        doc.perform("Use Part Photo") { h in
                            if let i = h.connectors.firstIndex(where: { $0.id == c.id }) { h.connectors[i].imagePNG = nil }
                        }
                    }
                }
                m.submenu("Mate In Line With", image: "link") { sub in
                    for other in h.connectors where other.id != c.id && !other.kind.isLooseTerminal {
                        sub.item(other.id) { doc.perform("Mate \(c.id) and \(other.id)") { $0.setMate(c.id, other.id) } }.state = c.mate == other.id ? .on : .off
                    }
                    if c.mate != nil {
                        sub.separator()
                        sub.item("Unmate") { doc.perform("Unmate \(c.id)") { $0.setMate(c.id, nil) } }
                    }
                }
                if !c.kind.isLooseTerminal {
                    m.item("Edit Connector Face…", image: "circle.grid.cross") { doc.faceEditor = FaceEditTarget(id: c.id) }
                    m.item("Export Face as SVG…", image: "square.and.arrow.up") { doc.exportFaceSVG(c.id) }
                }
                m.separator()
                wireItems(m, from: c.id)
                m.item("Add Connector Label", image: "tag") {
                    doc.perform("Add Label") { $0.labels.append(BundleLabel(id: $0.nextID(prefix: "L"), placement: .connector(c.id))) }
                }
            } else if let s = h.splices.first(where: { $0.nodeID == n }) {
                m.header("\(s.id) · \(s.kind.title)")
                wireItems(m, from: s.id)
                if s.tableOffset != nil {
                    m.item("Reset Table Position", image: "tablecells") {
                        doc.perform("Reset Table Position") { h in
                            if let i = h.splices.firstIndex(where: { $0.id == s.id }) { h.splices[i].tableOffset = nil }
                        }
                    }
                }
                m.submenu("Splice Type", image: "arrow.triangle.merge") { sub in
                    for k in SpliceKind.allCases {
                        sub.item(k.title) {
                            doc.perform("Change Splice Type") { h in
                                if let i = h.splices.firstIndex(where: { $0.id == s.id }) { h.splices[i].kind = k }
                            }
                        }.state = s.kind == k ? .on : .off
                    }
                }
            } else {
                m.header("\(node.label.isEmpty ? node.id : node.label) · \(node.kind.rawValue)")
                if node.kind == .breakout || node.kind == .clip {
                    let other: NodeKind = node.kind == .breakout ? .clip : .breakout
                    m.item("Convert to \(other.rawValue.capitalized)") {
                        doc.perform("Convert Node") { h in
                            if let i = h.nodes.firstIndex(where: { $0.id == n }) { h.nodes[i].kind = other }
                        }
                    }
                }
            }
            m.submenu("Connect Bundle To", image: "line.diagonal") { sub in
                for other in h.nodes where other.id != n && !h.segments.contains(where: { Set([$0.nodeA, $0.nodeB]) == Set([n, other.id]) }) {
                    sub.item(nodeTitle(other)) { doc.addSegment(n, other.id) }
                }
            }
            m.separator()
            m.item("Duplicate", key: "d", modifiers: .command, image: "plus.square.on.square") { doc.duplicateSelection() }
            m.item("Copy", key: "c", modifiers: .command, image: "doc.on.doc") { doc.copy() }
            m.separator()
            m.item("Delete", key: "\u{8}", image: "trash") { doc.deleteItems(doc.selectedIDs) }
            return m.menu
        }

        if let a = hitA, let ann = h.annotations.first(where: { $0.id == a }) {
            m.header("\(ann.kind.rawValue.capitalized) \(ann.id)")
            m.item("Bring to Front", image: "square.3.layers.3d.top.filled") {
                doc.perform("Bring to Front") { h in
                    let top = (h.annotations.map(\.z).max() ?? 0) + 1
                    if let i = h.annotations.firstIndex(where: { $0.id == a }) { h.annotations[i].z = top }
                }
            }
            m.item("Send to Back", image: "square.3.layers.3d.bottom.filled") {
                doc.perform("Send to Back") { h in
                    let bottom = (h.annotations.map(\.z).min() ?? 0) - 1
                    if let i = h.annotations.firstIndex(where: { $0.id == a }) { h.annotations[i].z = bottom }
                }
            }
            m.separator()
            m.item("Delete", key: "\u{8}", image: "trash") { doc.deleteItems([a]) }
            return m.menu
        }

        if let l = hitL {
            m.header("Label \(l)")
            m.item("Edit Label…", image: "pencil") { doc.selection = .label(l) }
            m.item("Delete", key: "\u{8}", image: "trash") { doc.deleteItems([l]) }
            return m.menu
        }

        if let (sid, t) = hitS, let seg = h.segment(sid) {
            m.header("\(sid) · \(doc.units.format(seg.lengthMM)) · Ø\(String(format: "%.1f", doc.analysis.bundleDiameterMM[sid] ?? 0)) mm")
            m.item("Insert Splice Here", key: "s", image: "arrow.triangle.merge") { doc.insert(.splice, at: p) }
            m.item("Insert Breakout Here", key: "j", image: "arrow.triangle.branch") { doc.insert(.breakout, at: p) }
            m.item("Insert Clip Here", key: "k", image: "paperclip") { doc.insert(.clip, at: p) }
            m.item("Add Label Here", key: "l", image: "tag") { doc.addLabel(on: sid, offsetMM: (t * seg.lengthMM).rounded()) }
            m.submenu("Add Covering", image: "cylinder") { sub in
                for k in CoveringKind.allCases { sub.item(k.title) { doc.addCovering(k, segments: [sid]) } }
            }
            m.item("Edit Segment…", image: "pencil") { doc.selection = .segment(sid) }
            m.separator()
            m.item("Delete Segment", key: "\u{8}", image: "trash") { doc.deleteItems([sid]) }
            return m.menu
        }

        // Empty canvas: everything that can be added, placed where you clicked.
        m.item("Place Component…", key: "c", image: "powerplug") { doc.insert(.connector, at: p) }
        m.item("In-Line Mated Pair…", key: "m", image: "link") { doc.insert(.matedPair, at: p) }
        m.item("Add Splice", key: "s", image: "arrow.triangle.merge") { doc.insert(.splice, at: p) }
        m.item("Add Breakout", key: "j", image: "arrow.triangle.branch") { doc.insert(.breakout, at: p) }
        m.item("Add Clip", key: "k", image: "paperclip") { doc.insert(.clip, at: p) }
        m.item("New Wire…", key: "w", image: "cable.connector.horizontal", enabled: !(h.connectors.isEmpty && h.splices.isEmpty)) { doc.insert(.wire) }
        m.submenu("Add Annotation", image: "textformat") { sub in
            sub.item("Sticky Note", key: "n") { doc.insert(.sticky, at: p) }
            sub.item("Frame", key: "g") { doc.insert(.frame, at: p) }
            sub.item("Text", key: "t") { doc.insert(.text, at: p) }
            sub.item("Arrow", key: "a") { doc.insert(.arrow, at: p) }
            sub.item("Box", key: "x") { doc.insert(.box, at: p) }
            sub.item("Image…", key: "i") { doc.insert(.image, at: p) }
        }
        m.separator()
        m.item("Paste", key: "v", modifiers: .command, image: "doc.on.clipboard", enabled: doc.canPaste) { doc.paste() }
        m.item("Select All", key: "a", modifiers: .command) { doc.selectAll() }
        m.separator()
        m.item("Zoom to Fit", key: "f") { zoomToFit(renderer) }
        m.item("Lay Out to Scale") { doc.perform("Lay Out to Scale") { $0.layoutToScale(pointsPerMM: 0.5) } }
        m.item("Keyboard Shortcuts", key: "?") { NotificationCenter.default.post(name: .showShortcuts, object: nil) }
        return m.menu
    }

    /// "New Wire from…" and "Wire To ▸" for a connector or splice.
    private func wireItems(_ m: MenuBuilder, from id: EntityID) {
        let h = doc.harness
        m.item("New Wire from \(id)…", key: "w", image: "cable.connector.horizontal") { doc.requestWire(from: id) }
        m.submenu("Wire To", image: "arrow.right") { sub in
            for c in h.connectors where c.id != id {
                sub.item([c.id, c.name].filter { !$0.isEmpty }.joined(separator: " ")) { doc.requestWire(from: id, to: c.id) }
            }
            if !h.splices.filter({ $0.id != id }).isEmpty {
                sub.separator()
                for s in h.splices where s.id != id { sub.item("\(s.id) (splice)") { doc.requestWire(from: id, to: s.id) } }
            }
            if h.connector(id) != nil {
                sub.separator()
                sub.item("Loopback (same connector)") { doc.requestWire(from: id, to: id) }
            }
        }
    }

    private func nodeTitle(_ n: TopologyNode) -> String {
        if let c = doc.harness.connectors.first(where: { $0.nodeID == n.id }) { return [c.id, c.name].filter { !$0.isEmpty }.joined(separator: " ") }
        if let s = doc.harness.splices.first(where: { $0.nodeID == n.id }) { return s.id }
        return n.label.isEmpty ? n.id : n.label
    }

    // MARK: Hit testing (model coordinates)

    private func hitNode(_ p: CGPoint) -> EntityID? {
        if let n = doc.harness.nodes.min(by: { hypot($0.position.x - p.x, $0.position.y - p.y) < hypot($1.position.x - p.x, $1.position.y - p.y) }),
           hypot(n.position.x - p.x, n.position.y - p.y) < 18 {
            return n.id
        }
        // Clicking a connector's photo or text selects the connector too, wherever they have been moved.
        return doc.harness.connectors.reversed().first { c in tagFrame(c)?.contains(p) == true }?.nodeID
    }

    /// A connector whose unlocked photo/text is under the pointer, with its node.
    private func hitUnlockedTag(_ p: CGPoint) -> (Connector, EntityID)? {
        for c in doc.harness.connectors.reversed() where c.tagUnlocked == true {
            if let f = tagFrame(c), f.insetBy(dx: -4, dy: -4).contains(p), let n = c.nodeID { return (c, n) }
        }
        return nil
    }

    /// The connector's photo and text as drawn (they sit on the side away from its bundle).
    private func tagFrame(_ c: Connector) -> CGRect? {
        hitRenderer.connectorTag(c)?.frame
    }

    private func hitAnnotation(_ p: CGPoint) -> EntityID? {
        doc.harness.annotations.sorted { $0.z > $1.z }.first {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).standardized.insetBy(dx: -6, dy: -6).contains(p)
        }?.id
    }

    private func hitLabel(_ p: CGPoint) -> EntityID? {
        let h = doc.harness
        for l in h.labels {
            guard case let .segment(sid, off) = l.placement, let s = h.segment(sid),
                  let a = h.node(s.nodeA)?.position, let b = h.node(s.nodeB)?.position, s.lengthMM > 0 else { continue }
            let t = min(max(off / s.lengthMM, 0), 1)
            let at = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t - 18)
            if abs(at.x - p.x) < 40 && abs(at.y - p.y) < 9 { return l.id }
        }
        return nil
    }

    /// A soft dot grid, like a cutting mat.
    /// Rulers along the top and left edges, in the harness's units, with a tick every grid step.
    private func drawRulers(_ ctx: GraphicsContext, _ size: CGSize) {
        guard showRulers else { return }
        let u = doc.harness.settings.units
        // One canvas point is 0.5 mm at "To Scale"; label the rulers in the same terms so To Scale drawings read true.
        let mmPerPoint = 2.0
        let step = max(doc.harness.settings.gridSize, 5) * 5 * zoom
        guard step > 12 else { return }
        let band: CGFloat = 16
        ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: band)), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
        ctx.fill(Path(CGRect(x: 0, y: 0, width: band, height: size.height)), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
        var ticks = Path()
        var i = 0
        for x in stride(from: 0.0, through: size.width, by: step) {
            ticks.move(to: CGPoint(x: x, y: band)); ticks.addLine(to: CGPoint(x: x, y: band - (i % 2 == 0 ? 8 : 4)))
            if i % 2 == 0 {
                let mm = x / zoom * mmPerPoint
                ctx.draw(Text(u.format(mm)).font(.system(size: 8)).foregroundStyle(.secondary), at: CGPoint(x: x + 3, y: 5), anchor: .leading)
            }
            i += 1
        }
        i = 0
        for y in stride(from: 0.0, through: size.height, by: step) {
            ticks.move(to: CGPoint(x: band, y: y)); ticks.addLine(to: CGPoint(x: band - (i % 2 == 0 ? 8 : 4), y: y))
            i += 1
        }
        ctx.stroke(ticks, with: .color(.secondary), lineWidth: 0.5)
    }

    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        let step = max(doc.harness.settings.gridSize, 5) * 5 * zoom
        guard step > 4 else { return }
        var dots = Path()
        for x in stride(from: 0.0, through: size.width, by: step) {
            for y in stride(from: 0.0, through: size.height, by: step) {
                dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
            }
        }
        ctx.fill(dots, with: .color(.secondary.opacity(0.35)))
    }
}

/// Finds the AppKit views behind the drawing so the canvas can measure what the sidebar, inspector and toolbar cover.
final class CanvasAnchor {
    weak var view: NSView?
    var refit: DispatchWorkItem?

    /// The drawing's visible area in window coordinates: the scroll view, minus the toolbar and any open
    /// sidebar or inspector column that floats over it.
    func visibleRect() -> CGRect? {
        guard let view, let window = view.window, let scroll = view.enclosingScrollView else { return nil }
        var r = scroll.convert(scroll.bounds, to: nil).intersection(window.contentLayoutRect)
        for side in Self.sideColumns(in: window, besides: view) {
            guard side.intersects(r) else { continue }
            if side.midX < r.midX { r = CGRect(x: max(r.minX, side.maxX), y: r.minY, width: r.maxX - max(r.minX, side.maxX), height: r.height) }
            else { r.size.width = min(r.maxX, side.minX) - r.minX }
        }
        return r.isNull || r.width <= 0 ? nil : r
    }

    /// Frames (window coordinates) of the window's open side columns: every column of a split view other than the
    /// one holding `canvas`. (Matching on the item's behavior isn't enough: on recent macOS, SwiftUI's inspector
    /// column isn't marked as an inspector, so it was counted as visible and the drawing fitted underneath it.)
    static func sideColumns(in window: NSWindow, besides canvas: NSView? = nil) -> [CGRect] {
        var out: [CGRect] = []
        func visit(_ vc: NSViewController) {
            if let split = vc as? NSSplitViewController {
                for item in split.splitViewItems where !item.isCollapsed && item.viewController.isViewLoaded {
                    let v = item.viewController.view
                    let holdsCanvas = canvas.map { $0.isDescendant(of: v) } ?? (item.behavior != .sidebar && item.behavior != .inspector)
                    if !holdsCanvas, !v.isHidden, v.frame.width > 1 { out.append(v.convert(v.bounds, to: nil)) }
                }
            }
            vc.children.forEach(visit)
        }
        if let root = window.contentViewController { visit(root) }
        return out
    }

    /// Scrolls so the drawing point (canvas coordinates, y down) lands on a window point.
    func scroll(canvasPoint p: CGPoint, toWindowPoint target: CGPoint) {
        guard let view, let scroll = view.enclosingScrollView else { return }
        let clip = scroll.contentView
        let here = view.convert(p, to: clip)
        let there = clip.convert(target, from: nil)
        var origin = clip.bounds.origin
        origin.x += here.x - there.x
        origin.y += here.y - there.y
        let constrained = clip.constrainBoundsRect(CGRect(origin: origin, size: clip.bounds.size)).origin
        clip.scroll(to: constrained)
        scroll.reflectScrolledClipView(clip)
    }
}

/// An invisible view placed behind the drawing; it hands its NSView to a `CanvasAnchor`.
struct CanvasAnchorView: NSViewRepresentable {
    let anchor: CanvasAnchor

    final class Probe: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let v = Probe()
        anchor.view = v
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { anchor.view = v }
}

extension UTType {
    static let loomoClip = UTType(importedAs: HarnessClip.pasteboardType)
}

extension Notification.Name {
    static let showShortcuts = Notification.Name("LoomoShowShortcuts")
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(s, radix: 16) ?? 0x333333
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

