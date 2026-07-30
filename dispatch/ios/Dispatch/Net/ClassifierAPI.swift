import Foundation

/// What the model decided about one headline.
enum ClassifierDecision: Equatable {
    case section(Topic)
    /// Belongs to no section at all — sport, celebrity, weather, a viral video.
    case unplaced
}

/// Files headlines with Claude instead of the lexicon.
///
/// The lexicon is a good scorer and a bad reader. It knows about five hundred
/// terms, and a wire that posts a hundred link headlines a day will use words
/// that are not among them all day long — which was fine while an unmatched
/// story fell back to the source's default topic, and became a disappearing act
/// the moment unmatched meant hidden. Adding terms is a treadmill: every headline
/// that goes missing is one more word to think of in advance.
///
/// So the model decides, and the lexicon becomes the offline answer. One request
/// carries forty headlines and costs a fraction of a cent on Haiku; a decision is
/// stored against the article id forever, so nothing is ever paid for twice.
///
/// The wire constants live in `SummaryAPI` — same endpoint, same header, same
/// model — rather than being written out again here where they could drift.
enum ClassifierAPI {

    /// Headlines per request. Big enough that a day of a busy wire is one or two
    /// calls; small enough that a truncated reply loses little.
    static let batchSize = 40

    /// Roughly six tokens a line plus slack.
    static let maxTokens = 600

    /// Bumped when the prompt changes *or* when stored answers are no longer
    /// trusted. `FeedStore` discards stored "none" decisions when this moves,
    /// which is how a run that hid too much stops hiding after it is fixed.
    static let promptRevision = 2

    static let systemPrompt =
        "You file news headlines into one section of a personal news app. The sections are:\n"
        + "war — armed conflict, militaries, defence, strikes, foreign crises and the "
        + "countries in them\n"
        + "politics — government, elections, courts, crime, policing, immigration, "
        + "protest, culture and the press\n"
        + "economics — markets, prices, the cost of living, the Fed, jobs, business\n"
        + "gaming — video games\n"
        + "none — belongs to no section: sport, celebrity, weather, animals, recipes, "
        + "viral video, human interest\n\n"
        + "Most headlines belong to a section. Use none only when a reader looking for "
        + "news would not want it in any of the four. When a headline could fit two, pick "
        + "the one a reader would look for it under.\n\n"
        + "Reply with one line per headline: the headline's number, a space, then one word "
        + "from war, politics, economics, gaming, none. No other text."

    /// The user turn: the headlines, numbered from 1.
    /// Mirrored in `tools/feed_reference.py`.
    static func prompt(titles: [String]) -> String {
        titles.enumerated()
            .map { index, title in "\(index + 1). \(ClassifierAPI.oneLine(title))" }
            .joined(separator: "\n")
    }

    /// A headline has to be one line, or the numbering stops meaning anything.
    static func oneLine(_ title: String) -> String {
        let flattened = title.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let collapsed = flattened.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return String(collapsed.prefix(200))
    }

    /// Parses the reply into decisions by line number.
    ///
    /// Tolerant on purpose: the format asked for is "3 politics", and what comes
    /// back is sometimes "3. politics", "3) Politics" or "3 - politics". A line
    /// that cannot be read is left out rather than guessed at, and a missing
    /// number simply keeps whatever the lexicon already decided.
    /// Mirrored in `tools/feed_reference.py`.
    static func parse(_ text: String) -> [Int: ClassifierDecision] {
        var out: [Int: ClassifierDecision] = [:]

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !line.isEmpty else { continue }

            // Leading digits are the index.
            var digits = ""
            var index = line.startIndex
            while index < line.endIndex, line[index].isNumber {
                digits.append(line[index])
                index = line.index(after: index)
            }
            guard let number = Int(digits) else { continue }

            // Then any of the separators a model reaches for, then the word.
            let rest = line[index...].drop { " .):-–—\t,".contains($0) }
            let word = rest.prefix { $0.isLetter }

            switch String(word) {
            case "war": out[number] = .section(.war)
            case "politics": out[number] = .section(.politics)
            case "economics": out[number] = .section(.economics)
            case "gaming": out[number] = .section(.gaming)
            case "none": out[number] = .unplaced
            default: continue
            }
        }
        return out
    }

    // MARK: - Request

    static func requestBody(titles: [String]) throws -> Data {
        let body: [String: Any] = [
            "model": SummaryAPI.model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": prompt(titles: titles)],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

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

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }()

    /// Files one batch. Returns decisions keyed by the *index in `titles`*, so a
    /// caller never has to think about the one-based numbering in the prompt.
    static func classify(titles: [String], key: String) async throws -> [Int: ClassifierDecision] {
        guard !titles.isEmpty else { return [:] }
        guard let url = URL(string: SummaryAPI.endpoint) else { throw SummaryAPI.SummaryError.empty }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(SummaryAPI.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try requestBody(titles: titles)

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SummaryAPI.SummaryError.badStatus(http.statusCode, nil)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if decoded.stopReason == "refusal" { throw SummaryAPI.SummaryError.refused }

        let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        let byNumber = parse(text)
        guard !byNumber.isEmpty else { throw SummaryAPI.SummaryError.empty }

        var byIndex: [Int: ClassifierDecision] = [:]
        for (number, decision) in byNumber where number >= 1 && number <= titles.count {
            byIndex[number - 1] = decision
        }
        return byIndex
    }
}
