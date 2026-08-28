import Charts
import SwiftUI

/// One instrument, full width: range picker, stats, and a chart you can
/// scrub with a finger.
struct ChartDetailScreen: View {

    enum ChartRange: String, CaseIterable, Identifiable {
        case month = "1M"
        case quarter = "3M"
        case half = "6M"
        case year = "1Y"

        var id: String { rawValue }

        var days: Int {
            switch self {
            case .month: return 22
            case .quarter: return 66
            case .half: return 130
            case .year: return 260
            }
        }
    }

    let instrument: Instrument

    @EnvironmentObject private var market: MarketStore
    @State private var range: ChartRange = .quarter
    @State private var selected: Quote?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                Picker("Range", selection: $range) {
                    ForEach(ChartRange.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if quotes.count >= 2 {
                    chart
                        .frame(height: 260)
                    stats
                } else {
                    Text(market.errors[instrument.id] ?? "No history available.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding()
        }
        .navigationTitle(instrument.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var quotes: [Quote] {
        Array((market.series[instrument.id] ?? []).suffix(range.days))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            // While scrubbing, the header becomes the readout for the point
            // under the finger.
            Text(PriceFormat.format((selected ?? quotes.last)?.close ?? 0))
                .font(.system(size: 34, weight: .semibold).monospacedDigit())
            HStack(spacing: 8) {
                if let selected {
                    Text(dateLabel(selected.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let first = quotes.first, let last = quotes.last, first.close != 0 {
                    let percent = (last.close - first.close) / first.close * 100
                    Text("\(PriceFormat.formatChange(percent)) over \(range.rawValue)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(percent >= 0 ? Color.green : Color.red)
                }
            }
        }
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            ForEach(quotes, id: \.date) { quote in
                AreaMark(
                    x: .value("Date", quote.date),
                    yStart: .value("Base", yDomain.lowerBound),
                    yEnd: .value("Close", quote.close)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [tint.opacity(0.25), tint.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))

                LineMark(
                    x: .value("Date", quote.date),
                    y: .value("Close", quote.close)
                )
                .lineStyle(StrokeStyle(lineWidth: 2))
                .foregroundStyle(tint)
            }

            if let selected {
                RuleMark(x: .value("Selected", selected.date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary)
                PointMark(
                    x: .value("Selected", selected.date),
                    y: .value("Close", selected.close)
                )
                .symbolSize(60)
                .foregroundStyle(tint)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 5))
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let origin = geometry[proxy.plotAreaFrame].origin
                                let x = drag.location.x - origin.x
                                if let date: Date = proxy.value(atX: x) {
                                    selected = nearest(to: date)
                                }
                            }
                            .onEnded { _ in selected = nil }
                    )
            }
        }
    }

    private var tint: Color {
        guard let first = quotes.first, let last = quotes.last else { return .green }
        return last.close >= first.close ? .green : .red
    }

    private var yDomain: ClosedRange<Double> {
        let closes = quotes.map { $0.close }
        guard let low = closes.min(), let high = closes.max(), low < high else {
            let value = closes.first ?? 0
            return (value - 1)...(value + 1)
        }
        let pad = (high - low) * 0.08
        return (low - pad)...(high + pad)
    }

    private func nearest(to date: Date) -> Quote? {
        quotes.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    // MARK: - Stats

    private var stats: some View {
        let closes = quotes.map { $0.close }
        return HStack {
            statCell("High", closes.max())
            Divider()
            statCell("Low", closes.min())
            Divider()
            statCell("Last", closes.last)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func statCell(_ label: String, _ value: Double?) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.map(PriceFormat.format) ?? "—")
                .font(.subheadline.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: .infinity)
    }

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
