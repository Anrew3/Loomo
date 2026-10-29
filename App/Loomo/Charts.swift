import Charts
import CrimpCore
import SwiftUI

/// A single-series horizontal bar chart: thin rounded bars in one colour, the value of the hovered bar
/// (and the largest one) labelled at its end. The page's table holds the same numbers.
struct BarChartCard: View {
    let title: String
    let bars: [ChartBar]
    var format: (Double) -> String
    var maxBars = 8
    @State private var hovered: String?

    private var shown: [ChartBar] {
        guard bars.count > maxBars else { return bars }
        // Fold the tail into "Other" rather than inventing more rows.
        let rest = bars.dropFirst(maxBars - 1).reduce(0) { $0 + $1.value }
        return Array(bars.prefix(maxBars - 1)) + [ChartBar(label: "Other", value: rest)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            if bars.isEmpty {
                Text("Nothing to show yet").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                // One row per item: name and value on a line, a slim bar underneath on a shared scale.
                // (Chart annotations get dropped in narrow columns, so the text sits outside the plot.)
                let maxValue = max(shown.map(\.value).max() ?? 1, .leastNonzeroMagnitude)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(shown) { bar in
                        let active = hovered == nil || hovered == bar.label
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(bar.label).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(format(bar.value)).monospacedDigit().foregroundStyle(hovered == bar.label ? .primary : .secondary)
                            }
                            .font(.caption)
                            Chart {
                                BarMark(xStart: .value("Start", 0), xEnd: .value("Value", bar.value), y: .value("Item", bar.label), height: .fixed(6))
                                    .cornerRadius(3)
                                    .foregroundStyle(Color.accentColor.opacity(active ? 1 : 0.4))
                            }
                            .chartXScale(domain: 0...maxValue)
                            .chartXAxis(.hidden)
                            .chartYAxis(.hidden)
                            .frame(height: 6)
                        }
                        .contentShape(Rectangle())
                        .onHover { hovered = $0 ? bar.label : (hovered == bar.label ? nil : hovered) }
                        .accessibilityElement(children: .combine)
                    }
                }
                .accessibilityLabel(title)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14)
    }
}

/// Charts above a table, with a control to hide them (remembered per page).
struct ChartStrip<Content: View>: View {
    let key: String
    @ViewBuilder var content: () -> Content
    @AppStorage private var shown: Bool

    init(key: String, @ViewBuilder content: @escaping () -> Content) {
        self.key = key
        self.content = content
        _shown = AppStorage(wrappedValue: true, "charts.\(key)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { shown.toggle() } } label: {
                Label(shown ? "Hide Charts" : "Show Charts", systemImage: shown ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if shown {
                HStack(alignment: .top, spacing: 12) { content() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, shown ? 6 : 2)
    }
}
