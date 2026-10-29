import CrimpCore
import SwiftUI

/// Loomo' look: a calm neutral window, Liquid Glass surfaces for panels and controls,
/// monochrome symbols, and colour only where it means something (status, wire colours, selection).
enum Theme {
    static let panelRadius: CGFloat = 18
}

extension Pane {
    /// Each page's colour, used for its sidebar tile, header and backdrop.
    var tint: Color {
        switch self {
        case .topology: Color(red: 0.20, green: 0.55, blue: 1.00)
        case .connectors: Color(red: 1.00, green: 0.55, blue: 0.15)
        case .wires: Color(red: 0.20, green: 0.78, blue: 0.45)
        case .cables: Color(red: 0.62, green: 0.40, blue: 0.98)
        case .splices: Color(red: 1.00, green: 0.36, blue: 0.56)
        case .coverings: Color(red: 0.85, green: 0.62, blue: 0.20)
        case .labels: Color(red: 0.10, green: 0.72, blue: 0.75)
        case .drawing: Color(red: 0.45, green: 0.50, blue: 0.62)
        case .bom: Color(red: 0.36, green: 0.40, blue: 0.95)
        case .cutList: Color(red: 0.95, green: 0.33, blue: 0.30)
        case .connectorTables: Color(red: 0.25, green: 0.70, blue: 0.62)
        case .netlist: Color(red: 0.15, green: 0.65, blue: 0.95)
        case .labelList: Color(red: 0.10, green: 0.62, blue: 0.70)
        case .tools: Color(red: 0.50, green: 0.55, blue: 0.60)
        case .issues: Color(red: 0.30, green: 0.75, blue: 0.40)
        case .export: Color(red: 0.55, green: 0.35, blue: 0.95)
        }
    }

    var blurb: String {
        switch self {
        case .topology: "Lay out bundles, connectors and splices"
        case .connectors: "Housings, cavities, terminals and seals"
        case .wires: "Every conductor, its ends, size and colour"
        case .cables: "Multicore cables and twisted pairs"
        case .splices: "Joins and their wires"
        case .coverings: "Tube, sleeve, heat shrink and tape"
        case .labels: "Bundle and connector labels"
        case .drawing: "Notes, revisions and the title block"
        case .bom: "Everything to buy, with quantities and prices"
        case .cutList: "Wire cut lengths for the shop floor"
        case .connectorTables: "Pin-by-pin tables per connector"
        case .netlist: "Signals and what they connect"
        case .labelList: "Labels to print"
        case .tools: "Crimp tools and equipment"
        case .issues: "Design rule checks"
        case .export: "PDF drawing sets, Excel and WireViz"
        }
    }
}

/// A monochrome symbol on a small Liquid Glass chip. `tint` is kept for callers that pass a status colour.
struct IconTile: View {
    let systemName: String
    var tint: Color = .secondary
    var size: CGFloat = 24
    /// Tint the symbol (status icons); otherwise it stays neutral.
    var colored = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(colored ? AnyShapeStyle(tint) : AnyShapeStyle(.primary.opacity(0.8)))
            .frame(width: size, height: size)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// The page backdrop: the plain window colour. `tint` is accepted but no longer coloured.
struct AmbientBackground: View {
    var tint: Color = .clear
    var intensity: Double = 1
    var canvas = false

    var body: some View {
        Color(nsColor: canvas ? .underPageBackgroundColor : .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

extension View {
    /// A Liquid Glass content panel (tables, editors).
    func glassPanel(cornerRadius: CGFloat = Theme.panelRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            .clipShape(shape)
            .glassEffect(.regular, in: shape)
    }

    /// A small glass card used in the inspector, sidebar and sheets.
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// The big title at the top of each page.
struct PaneHeader<Trailing: View>: View {
    let title: String
    let icon: String
    let tint: Color
    var subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(pane: Pane, subtitle: String? = nil) {
        self.init(title: pane.rawValue, icon: pane.icon, tint: pane.tint, subtitle: subtitle ?? pane.blurb) { EmptyView() }
    }

    init(title: String, icon: String, tint: Color, subtitle: String) {
        self.init(title: title, icon: icon, tint: tint, subtitle: subtitle) { EmptyView() }
    }
}

/// A big number with an icon, for summaries.
struct StatTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    var action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: icon).font(.caption).foregroundStyle(.tertiary)
                }
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard()
        .disabled(action == nil)
    }
}

/// A sidebar row: icon tile, title, count.
struct SidebarRow: View {
    let title: String
    let icon: String
    let tint: Color
    var detail: String?
    var count: Int = 0
    var countTint: Color?

    init(title: String, icon: String, tint: Color, detail: String? = nil, count: Int = 0, countTint: Color? = nil) {
        self.title = title; self.icon = icon; self.tint = tint; self.detail = detail; self.count = count; self.countTint = countTint
    }

    init(pane: Pane, count: Int = 0, countTint: Color? = nil) {
        self.init(title: pane.rawValue, icon: pane.icon, tint: pane.tint, count: count, countTint: countTint)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title).lineLimit(1)
            if let detail { Text(detail).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(countTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.\(title)")
        .accessibilityValue("\(count)")
    }
}

/// The app mark shown at the top of the sidebar.
struct BrandHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            IconTile(systemName: "point.3.connected.trianglepath.dotted", size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Errors and warnings at a glance; sits at the bottom of the sidebar.
struct HealthCard: View {
    let errors: Int
    let warnings: Int
    /// Reviewed deviations; shown so a clean check never hides what was accepted.
    var accepted: Int = 0
    var action: () -> Void

    var body: some View {
        let ok = errors + warnings == 0
        let tint: Color = errors > 0 ? .red : warnings > 0 ? .orange : .green
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: errors > 0 ? "xmark.octagon.fill" : warnings > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ok ? "No issues" : "Needs attention").font(.callout.weight(.medium))
                    Text(ok ? (accepted > 0 ? "\(accepted) accepted deviation\(accepted == 1 ? "" : "s")" : "No rule-check issues")
                            : "\(errors) errors · \(warnings) warnings")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard()
        .padding(10)
    }
}
