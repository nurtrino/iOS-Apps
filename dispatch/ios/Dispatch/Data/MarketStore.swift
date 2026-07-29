import Foundation

/// The two prices at the top of the Markets screen.
@MainActor
final class MarketStore: ObservableObject {

    @Published private(set) var series: [MarketSeries] = []
    @Published private(set) var phase: LoadPhase = .idle

    private let cacheFile = "markets"
    /// Quotes go stale fast, but not so fast that switching tabs should refetch
    /// them. A minute is the sweet spot between live and rude.
    private let freshness: TimeInterval = 60
    private var lastFetched: Date?

    init(load: Bool = true) {
        guard load else { return }
        // The last quote on screen immediately, so the cards are never two
        // empty grey rectangles while the network answers.
        if let cached = DiskStore.load([MarketSeries].self, from: cacheFile), !cached.isEmpty {
            series = cached
            phase = .loaded
        }
    }

    var isStale: Bool {
        guard let lastFetched else { return true }
        return Date().timeIntervalSince(lastFetched) >= freshness
    }

    func refresh(force: Bool = false) async {
        guard force || isStale else { return }
        phase = series.isEmpty ? .loading : .refreshing

        // Both at once, and one failing does not take the other down — a dead
        // Yahoo endpoint should not blank the Bitcoin card.
        let fetched = await withTaskGroup(of: MarketSeries?.self) { group -> [MarketSeries] in
            group.addTask { try? await MarketAPI.bitcoin() }
            group.addTask { try? await MarketAPI.sp500() }

            var collected: [MarketSeries] = []
            for await quote in group {
                if let quote { collected.append(quote) }
            }
            return collected
        }

        guard !fetched.isEmpty else {
            phase = series.isEmpty
                ? .failed("Could not reach either price source.")
                : .loaded
            return
        }

        // Merge rather than replace: if only one provider answered, the other
        // card keeps its last known price with its own timestamp rather than
        // disappearing.
        var merged = series
        for quote in fetched {
            if let index = merged.firstIndex(where: { $0.symbol == quote.symbol }) {
                merged[index] = quote
            } else {
                merged.append(quote)
            }
        }
        // A stable order, so the cards do not swap places depending on which
        // request finished first.
        series = merged.sorted { $0.symbol < $1.symbol }
        lastFetched = Date()
        phase = .loaded
        DiskStore.save(series, to: cacheFile)
    }

    func quote(symbol: String) -> MarketSeries? {
        series.first { $0.symbol == symbol }
    }
}
