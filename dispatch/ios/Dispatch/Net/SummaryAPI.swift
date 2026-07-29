import Foundation

/// The Claude API, used for exactly one thing: turning a topic's newest
/// headlines into the two or three sentences at the top of the section.
///
/// Raw HTTP against `POST /v1/messages` rather than an SDK, because Anthropic
/// ships no Swift SDK and the request is a single JSON document either way.
/// What goes over the wire is deliberately minimal — the headlines the brief
/// already shows, their source names and their ages. No article bodies, no
/// reading history, nothing about the library. The Settings screen makes that
/// promise in writing, so this file is where it has to be kept.
enum SummaryAPI {

    /// Constants the Python suite asserts on, so a typo here fails a test
    /// instead of failing silently against the live API.
    static let endpoint = "https://api.anthropic.com/v1/messages"
    static let apiVersion = "2023-06-01"
    /// Haiku rather than an Opus, deliberately: the job is four lines off five
    /// headlines that are already written, this runs a few times an hour across
    /// four sections all day, and it is a fifth of the price. If the lines ever
    /// read badly, this constant is the knob.
    static let model = "claude-haiku-4-5"
    static let maxTokens = 300

    /// Bumped whenever the prompt or the model changes.
    ///
    /// It is part of the cache key, so a rewrite here invalidates every stored
    /// brief instead of leaving yesterday's prose sitting under a new prompt
    /// until its headlines happen to change.
    static let promptRevision = 2

    /// One headline as the model sees it. A struct rather than passing
    /// `Article` through so the prompt builder is a pure function of visible
    /// strings — which is what lets the Python mirror test it byte for byte.
    struct Headline {
        let title: String
        let source: String
        let age: String?
    }

    enum SummaryError: LocalizedError {
        case badStatus(Int, String?)
        case refused
        case empty

        var errorDescription: String? {
            switch self {
            case .badStatus(let code, let message):
                switch code {
                case 401: return "Anthropic rejected the API key."
                case 429: return "Rate limited by Anthropic — try again in a minute."
                case 529: return "Anthropic's API is overloaded right now."
                default: return message.map { "Anthropic: \($0)" } ?? "Anthropic returned HTTP \(code)."
                }
            case .refused: return "The model declined to summarize this."
            case .empty: return "Anthropic returned an empty summary."
            }
        }
    }

    // MARK: - Prompt

    /// What the model is, permanently. Sent as the system prompt on every
    /// request, so it caches well and the per-request text is just the data.
    static let systemPrompt =
        "You write the brief at the top of a section in a personal news app. "
        + "Given the newest headlines, write two to four short lines covering what just "
        + "happened, most consequential first, so the reader knows the state of things "
        + "before scanning the list. "
        + "One line per point, separated by newlines. Each line is a single clause or "
        + "short sentence under about twenty words. "
        + "Where several headlines are the same story, merge them into one line. "
        + "Keep concrete numbers, names and places from the headlines; never add facts "
        + "the headlines do not contain. "
        + "No bullet characters, no numbering, no markdown, no preamble — just the lines."

    /// The user turn. Pure string building, mirrored in
    /// `tools/feed_reference.py` and pinned by `test_feeds.py`.
    static func prompt(topic: String, headlines: [Headline]) -> String {
        var lines = ["Section: \(topic)", "Headlines, newest first:"]
        for headline in headlines {
            let age = headline.age.map { ", \($0)" } ?? ""
            lines.append("- [\(headline.source)\(age)] \(headline.title)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Bullets

    /// Splits a generated brief into the lines the section renders as bullets.
    ///
    /// The prompt asks for one point per line and no bullet characters, and
    /// mostly gets it — but a model that decides to be helpful and prefix every
    /// line with "- " or "1. " must not produce a screen of double bullets. So
    /// markers are stripped here rather than trusted away.
    static func bullets(from text: String) -> [String] {
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw.replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespaces)
            line = stripMarker(stripMarker(line))
            // One character is punctuation left behind, not a point.
            guard line.count > 1 else { continue }
            lines.append(line)
        }
        return lines
    }

    /// Removes one leading list marker: a dash-like glyph, or a short number
    /// followed by a dot or bracket.
    private static func stripMarker(_ line: String) -> String {
        guard let first = line.first else { return line }

        if "-–—*•·".contains(first) {
            return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // "1. " is a marker. "3.4% inflation" is not, which is why the digits
        // have to be followed by a separator *and* a space — checking only for
        // the dot would turn a number into "4% inflation".
        guard first.isNumber else { return line }
        var index = line.startIndex
        var digits = 0
        while index < line.endIndex, line[index].isNumber, digits < 2 {
            index = line.index(after: index)
            digits += 1
        }
        guard index < line.endIndex, ".)".contains(line[index]) else { return line }
        let afterSeparator = line.index(after: index)
        guard afterSeparator < line.endIndex, line[afterSeparator] == " " else { return line }
        return String(line[afterSeparator...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Request

    /// The request body as data. Built with `JSONSerialization` from a
    /// dictionary rather than an `Encodable` struct because the API's names
    /// (`max_tokens`, `system`) are wire format, not Swift style, and a
    /// dictionary keeps them visibly exact.
    static func requestBody(topic: String, headlines: [Headline]) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": prompt(topic: topic, headlines: headlines),
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // MARK: - Response

    /// The parts of a Messages API response this app reads. `content` is an
    /// array of typed blocks; only the `text` ones matter here.
    private struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    /// The error envelope Anthropic wraps non-2xx responses in.
    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let message: String?
        }
        let error: Detail?
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    /// One brief. Throws with a message worth showing in Settings rather than
    /// swallowing failures — a wrong key that fails silently just looks like
    /// the feature not existing.
    static func summarize(topic: String, headlines: [Headline], key: String) async throws -> String {
        guard let url = URL(string: endpoint) else { throw SummaryError.empty }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try requestBody(topic: topic, headlines: headlines)

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let detail = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            throw SummaryError.badStatus(http.statusCode, detail?.error?.message)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)

        // A refusal is a real terminal state, not a parse failure — the model
        // looked at the input and said no. Treat it as such.
        if decoded.stopReason == "refusal" { throw SummaryError.refused }

        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw SummaryError.empty }
        return text
    }

    /// The cheapest possible round trip, for the "does this key work" button.
    static func verify(key: String) async throws {
        _ = try await summarize(
            topic: "Test",
            headlines: [Headline(title: "Reply with the single word OK.", source: "Dispatch", age: nil)],
            key: key
        )
    }
}
