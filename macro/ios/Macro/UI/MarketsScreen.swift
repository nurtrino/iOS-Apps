import Charts
import SwiftUI

/// The watchlist: price, day change and a month's sparkline per instrument.
struct MarketsScreen: View {

    @EnvironmentObject private var market: MarketStore

    var body: some View {
        Group {
            if market.series.isEmpty && market.isLoading {
                LoadingView(label: "Fetching prices…")
            } else if market.series.isEmpty, let firstError = market.errors.values.first {
                ErrorView(message: firstError) {
                    Task { await market.refresh() }
                }
            } else {
                list
            }
        }
        .navigationTitle("Markets")
        .refreshable { await market.refresh() }
        .task { await market.refreshIfStale() }
        .navigationDestination(for: Instrument.self) { instrument in
            ChartDetailScreen(instrument: instrument)
        }
    }

    private var list: some View {
        List {
            ForEach(Instrument.Group.allCases) { group in
                let members = Instrument.all.filter { $0.group == group }
                Section(group.rawValue) {
                    ForEach(members) { instrument in
                        if let quotes = market.series[instrument.id], quotes.count >= 2 {
                            NavigationLink(value: instrument) {
                                InstrumentRow(instrument: instrument, quotes: quotes)
                            }
                        } else {
                            quietRow(instrument)
                        }
                    }
                }
            }
            Section {
                Text("Data: Stooq daily closes, ECB reference rates for FX fallback. Unofficial keyless endpoints — treat as indicative, not tradable.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func quietRow(_ instrument: Instrument) -> some View {
        HStack {
            Text(instrument.name)
                .foregroundStyle(.secondary)
            Spacer()
            Text(market.errors[instrument.id] == nil ? "…" : "no data")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct InstrumentRow: View {
    let instrument: Instrument
    let quotes: [Quote]

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(instrument.name)
                    .font(.body.weight(.medium))
                Text(instrument.id.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Sparkline(quotes: Array(quotes.suffix(30)), rising: isRising)
                .frame(width: 72, height: 28)

            VStack(alignment: .trailing, spacing: 2) {
                Text(PriceFormat.format(last.close))
                    .font(.body.monospacedDigit())
                Text(PriceFormat.formatChange(changePercent))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isRising ? Color.green : Color.red)
            }
        }
    }

    private var last: Quote { quotes[quotes.count - 1] }
    private var previous: Quote { quotes[quotes.count - 2] }

    private var changePercent: Double {
        previous.close == 0 ? 0 : (last.close - previous.close) / previous.close * 100
    }

    private var isRising: Bool { last.close >= previous.close }
}

/// A month in seventy points, axes hidden.
struct Sparkline: View {
    let quotes: [Quote]
    let rising: Bool

    var body: some View {
        Chart(quotes, id: \.date) { quote in
            LineMark(
                x: .value("Date", quote.date),
                y: .value("Close", quote.close)
            )
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            .foregroundStyle(rising ? Color.green : Color.red)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: yDomain)
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
}
