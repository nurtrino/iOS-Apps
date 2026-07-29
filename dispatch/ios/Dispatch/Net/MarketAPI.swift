import Foundation

/// A price history, ready to draw.
struct MarketSeries: Codable, Hashable {
    let symbol: String
    let name: String
    /// Chronological closes, oldest first.
    let points: [Double]
    let last: Double
    /// The reference the change is measured against — yesterday's close for an
    /// index, the price 24 hours ago for something that trades around the
    /// clock.
    let previousClose: Double
    let updated: Date
    /// Where it came from, shown in small print. These are unofficial public
    /// endpoints and it is only fair to say which one answered.
    let provider: String

    var change: Double { last - previousClose }

    var changePercent: Double {
        previousClose == 0 ? 0 : (change / previousClose) * 100
    }

    var isUp: Bool { change >= 0 }

    /// Formatted for the card, with the precision each instrument deserves.
    var formattedLast: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = last >= 1000 ? 0 : 2
        formatter.minimumFractionDigits = last >= 1000 ? 0 : 2
        return formatter.string(from: NSNumber(value: last)) ?? "—"
    }

    var formattedChange: String {
        String(format: "%@%.2f%%", change >= 0 ? "+" : "−", abs(changePercent))
    }
}

/// Prices, from endpoints that need no key.
///
/// Every one of these is a public, unauthenticated endpoint, and none of them
/// promises to stay that way — so each instrument has a fallback provider and
/// the card says which one answered. The alternative is a paid market data
/// vendor and an API key in the app, for two numbers and a sparkline.
enum MarketAPI {

    // MARK: - Bitcoin

    /// Coinbase's public candles endpoint. No key, no rate-limit headaches at
    /// one call a minute, and it is the exchange the price is quoted from
    /// anyway.
    static func bitcoin() async throws -> MarketSeries {
        var components = URLComponents(string: "https://api.exchange.coinbase.com/products/BTC-USD/candles")!
        // 15-minute buckets, which fills a day with 96 points — enough shape
        // for a sparkline without pulling 1,440 of them.
        components.queryItems = [URLQueryItem(name: "granularity", value: "900")]
        guard let url = components.url else { throw FeedError.badURL("coinbase") }

        // [ [ time, low, high, open, close, volume ], … ] newest first.
        let rows = try await HTTP.shared.json([[Double]].self, from: url)
        let ordered = rows.reversed().compactMap { row -> Double? in
            row.count >= 5 ? row[4] : nil
        }
        guard let last = ordered.last, ordered.count > 2 else { throw FeedError.empty }

        // A day back, or the oldest point available if the window is short.
        let dayAgo = ordered.count >= 96 ? ordered[ordered.count - 96] : ordered[0]

        return MarketSeries(symbol: "BTC", name: "Bitcoin",
                            points: Array(ordered.suffix(96)),
                            last: last, previousClose: dayAgo,
                            updated: Date(), provider: "Coinbase")
    }

    // MARK: - S&P 500

    static func sp500() async throws -> MarketSeries {
        do {
            return try await yahooChart(symbol: "^GSPC", name: "S&P 500")
        } catch {
            // Stooq is daily-only, so the sparkline becomes a two-week line
            // rather than an intraday one — worth having when Yahoo's
            // undocumented endpoint decides it wants a session cookie.
            return try await stooqDaily(symbol: "^spx", name: "S&P 500")
        }
    }

    private struct YahooChart: Decodable {
        struct Root: Decodable {
            let result: [Result]?
        }
        struct Result: Decodable {
            let meta: Meta
            let indicators: Indicators
        }
        struct Meta: Decodable {
            let regularMarketPrice: Double?
            let chartPreviousClose: Double?
            let previousClose: Double?
        }
        struct Indicators: Decodable {
            let quote: [Quote]
        }
        struct Quote: Decodable {
            let close: [Double?]?
        }
        let chart: Root
    }

    private static func yahooChart(symbol: String, name: String) async throws -> MarketSeries {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? symbol
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)")!
        components.queryItems = [
            URLQueryItem(name: "range", value: "1d"),
            URLQueryItem(name: "interval", value: "5m"),
        ]
        guard let url = components.url else { throw FeedError.badURL(symbol) }

        let payload = try await HTTP.shared.json(YahooChart.self, from: url)
        guard let result = payload.chart.result?.first else { throw FeedError.empty }

        // Gaps are normal in intraday data — a bucket with no trades comes back
        // null — and carrying them through would put holes in the line.
        let closes = (result.indicators.quote.first?.close ?? []).compactMap { $0 }
        guard !closes.isEmpty else { throw FeedError.empty }

        let last = result.meta.regularMarketPrice ?? closes[closes.count - 1]
        let previous = result.meta.chartPreviousClose ?? result.meta.previousClose ?? closes[0]

        return MarketSeries(symbol: "SPX", name: name,
                            points: Array(closes.suffix(120)),
                            last: last, previousClose: previous,
                            updated: Date(), provider: "Yahoo Finance")
    }

    /// Stooq serves plain CSV with no key and no cookie.
    private static func stooqDaily(symbol: String, name: String) async throws -> MarketSeries {
        guard let url = URL(string: "https://stooq.com/q/d/l/?s=\(symbol)&i=d") else {
            throw FeedError.badURL(symbol)
        }
        let data = try await HTTP.shared.data(from: url, accept: "text/csv,*/*")
        let text = String(decoding: data, as: UTF8.self)

        // Date,Open,High,Low,Close,Volume
        var closes: [Double] = []
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 5, let close = Double(fields[4]) else { continue }
            closes.append(close)
        }
        guard closes.count >= 2 else { throw FeedError.empty }

        let window = Array(closes.suffix(30))
        return MarketSeries(symbol: "SPX", name: name,
                            points: window,
                            last: window[window.count - 1],
                            previousClose: window[window.count - 2],
                            updated: Date(), provider: "Stooq (daily)")
    }
}
