import Foundation

/// Price histories for the watchlist.
@MainActor
final class MarketStore: ObservableObject {

    @Published private(set) var series: [String: [Quote]] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefreshed: Date?

    func refreshIfStale() async {
        if let last = lastRefreshed, Date().timeIntervalSince(last) < 10 * 60,
           !series.isEmpty {
            return
        }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        await withTaskGroup(of: (String, Result<[Quote], Error>).self) { group in
            for instrument in Instrument.all {
                group.addTask {
                    do {
                        return (instrument.id, .success(try await MarketAPI.history(for: instrument)))
                    } catch {
                        return (instrument.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let quotes):
                    series[id] = quotes
                    errors[id] = nil
                case .failure(let error):
                    // Keep any history already on screen; only record the
                    // error for instruments with nothing to show.
                    if series[id] == nil {
                        errors[id] = error.localizedDescription
                    }
                }
            }
        }
        if !series.isEmpty { lastRefreshed = Date() }
    }

    /// Last close and the one before it, for the row's price and day change.
    func lastPair(for id: String) -> (last: Quote, previous: Quote)? {
        guard let quotes = series[id], quotes.count >= 2 else { return nil }
        return (quotes[quotes.count - 1], quotes[quotes.count - 2])
    }
}
