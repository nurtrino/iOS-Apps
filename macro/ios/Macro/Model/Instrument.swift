import Foundation

/// One daily close.
struct Quote: Hashable {
    let date: Date
    let close: Double
}

/// One chartable thing, keyed by its Stooq symbol.
struct Instrument: Identifiable, Hashable {
    enum Group: String, CaseIterable, Identifiable {
        case indices = "Indices"
        case fx = "Currencies"
        case commodities = "Commodities"
        case crypto = "Crypto"
        case rates = "Rates"

        var id: String { rawValue }
    }

    /// The Stooq symbol, lowercase, e.g. "^spx" or "eurusd".
    let id: String
    let name: String
    let group: Group

    /// The base/quote pair for an FX symbol, which is what the Frankfurter
    /// fallback needs. Six letters means a pair; anything else is not FX.
    var fxPair: (base: String, quote: String)? {
        guard group == .fx, id.count == 6, id.allSatisfy({ $0.isLetter }) else { return nil }
        let upper = id.uppercased()
        return (String(upper.prefix(3)), String(upper.suffix(3)))
    }

    /// The desk's watchlist. Every symbol was chosen because Stooq serves
    /// daily history for it without a key.
    static let all: [Instrument] = [
        Instrument(id: "^spx", name: "S&P 500", group: .indices),
        Instrument(id: "^ndq", name: "Nasdaq 100", group: .indices),
        Instrument(id: "^dji", name: "Dow Jones", group: .indices),
        Instrument(id: "eurusd", name: "EUR/USD", group: .fx),
        Instrument(id: "gbpusd", name: "GBP/USD", group: .fx),
        Instrument(id: "usdjpy", name: "USD/JPY", group: .fx),
        Instrument(id: "audusd", name: "AUD/USD", group: .fx),
        Instrument(id: "xauusd", name: "Gold", group: .commodities),
        Instrument(id: "xagusd", name: "Silver", group: .commodities),
        Instrument(id: "cl.f", name: "WTI Crude", group: .commodities),
        Instrument(id: "btcusd", name: "Bitcoin", group: .crypto),
        Instrument(id: "10yusy.b", name: "US 10Y Yield", group: .rates),
    ]

    static func instrument(withID id: String) -> Instrument? {
        all.first { $0.id == id }
    }
}
