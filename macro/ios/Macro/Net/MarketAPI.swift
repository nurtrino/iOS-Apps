import Foundation

/// Daily price history, from endpoints that need no key.
///
/// Stooq serves plain CSV daily history for everything on the watchlist —
/// indices, spot metals, futures, FX, Bitcoin, even treasury yields — with no
/// key and no cookie. It promises nothing, so FX pairs carry a second provider:
/// Frankfurter republishes ECB reference rates as JSON, also keyless. The
/// alternative is a paid market data vendor and an API key in the app, for a
/// dozen line charts.
enum MarketAPI {

    /// About a year of daily closes, oldest first.
    static func history(for instrument: Instrument) async throws -> [Quote] {
        do {
            return try await stooqDaily(symbol: instrument.id)
        } catch {
            guard let pair = instrument.fxPair else { throw error }
            return try await frankfurter(base: pair.base, quote: pair.quote)
        }
    }

    // MARK: - Stooq

    static func stooqDaily(symbol: String) async throws -> [Quote] {
        // URLComponents percent-encodes the "^" in index symbols.
        var components = URLComponents(string: "https://stooq.com/q/d/l/")!
        components.queryItems = [
            URLQueryItem(name: "s", value: symbol),
            URLQueryItem(name: "i", value: "d"),
        ]
        guard let url = components.url else { throw FeedError.badURL(symbol) }

        let data = try await HTTP.shared.data(from: url, accept: "text/csv,text/plain,*/*")
        let text = String(decoding: data, as: UTF8.self)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        // Date,Open,High,Low,Close,Volume — and "No data" as the whole body
        // when the symbol is wrong or the host is rate limiting.
        var quotes: [Quote] = []
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 5,
                  let date = formatter.date(from: String(fields[0])),
                  let close = Double(fields[4]) else { continue }
            quotes.append(Quote(date: date, close: close))
        }

        // A real daily history has hundreds of rows. A handful means an error
        // page that happened to contain commas — treat it as a miss so the FX
        // fallback gets its turn.
        guard quotes.count >= 20 else { throw FeedError.empty }
        return Array(quotes.suffix(280))
    }

    // MARK: - Frankfurter (ECB reference rates)

    private struct FrankfurterSeries: Decodable {
        let rates: [String: [String: Double]]
    }

    static func frankfurter(base: String, quote: String) async throws -> [Quote] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        let start = formatter.string(
            from: Date(timeIntervalSinceNow: -370 * 24 * 3600))

        var components = URLComponents(string: "https://api.frankfurter.dev/v1/\(start)..")!
        components.queryItems = [
            URLQueryItem(name: "base", value: base),
            URLQueryItem(name: "symbols", value: quote),
        ]
        guard let url = components.url else { throw FeedError.badURL(base + quote) }

        let payload = try await HTTP.shared.json(FrankfurterSeries.self, from: url)

        let quotes = payload.rates.compactMap { day, values -> Quote? in
            guard let date = formatter.date(from: day),
                  let value = values[quote] else { return nil }
            return Quote(date: date, close: value)
        }
        guard quotes.count >= 2 else { throw FeedError.empty }
        return quotes.sorted { $0.date < $1.date }
    }
}
