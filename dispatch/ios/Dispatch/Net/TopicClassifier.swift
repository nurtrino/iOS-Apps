import Foundation

/// What the classifier decided, and how sure it was.
struct TopicVerdict: Equatable {
    /// Where the story goes, or **nil** when it goes nowhere.
    ///
    /// Nil is the outcome for a source that drops what it cannot place. A link
    /// aggregator posts a hundred things a day and some of them are a bear in a
    /// supermarket; filing those under the source's default topic does not make
    /// them politics, it makes Politics wrong. See `Source.dropsUnsortable`.
    let topic: Topic?
    let confidence: Double
    /// The terms that carried the decision, strongest first. Shown in the
    /// article's "why is this here?" line, which is the only honest way to ship
    /// a heuristic — if it puts a story in the wrong place you can see exactly
    /// what fooled it.
    let evidence: [String]
    /// True when nothing scored high enough: either the source's default was
    /// used, or — where the source drops what it cannot place — nothing was.
    let isFallback: Bool
}

/// Sorts a story into War, Politics or Markets.
///
/// This is a weighted lexicon scorer, not a language model. That is a
/// deliberate choice and worth being plain about: an on-device model large
/// enough to beat a good keyword list would add tens of megabytes and a second
/// of latency per refresh, and a hosted one would mean shipping an API key and
/// sending every headline someone reads to a third party. A tuned lexicon runs
/// in microseconds, works offline, and — this is the part that matters — is
/// inspectable and testable, so a misfile is a term to adjust rather than a
/// shrug.
///
/// Three things make it better than a naive keyword match:
///
/// **Phrases outrank words.** The words that belong to two topics at once are
/// exactly the ones a naive matcher gets wrong. "Strike" is worth nothing on
/// its own; "air strike" and "strike vote" are worth a lot, in different
/// directions. Same for "bank" versus "central bank" versus "West Bank".
///
/// **The headline counts for more than the body.** A markets piece that
/// mentions Ukraine in its fourth paragraph is still a markets piece.
///
/// **Distinct terms, not occurrences.** Counting every occurrence lets one
/// repeated word in a long article outvote five different signals in a short
/// one.
enum TopicClassifier {

    /// A headline is worth this many body mentions.
    static let titleWeight = 2.2

    /// Below this, nothing was really said about any topic and the source's
    /// own default wins.
    static let minimumScore = 3.0

    /// How far ahead the winner must be to count as a confident call. Below
    /// it the verdict still stands — something has to be chosen — but the
    /// confidence is reported low.
    static let decisiveMargin = 0.35

    /// A nudge towards what the source usually publishes.
    ///
    /// Small on purpose. It should break a tie between Politics and Markets on
    /// a ZeroHedge piece, and never drag an obvious battlefield report out of
    /// War.
    static let sourcePriorWeight = 1.25

    private struct Phrase {
        let text: String
        /// The phrase's first word, used to skip the substring scan entirely.
        let head: String
        let weight: Double
    }

    private struct Lexicon {
        let topic: Topic
        let words: [String: Double]
        let phrases: [Phrase]
    }

    /// Split once, at first use, into single words and multi-word phrases.
    ///
    /// Words go in a dictionary for O(1) lookup; phrases need a substring scan,
    /// and there are far fewer of them. Doing this per article instead would
    /// rebuild both tables for every row in the feed.
    private static let lexicons: [Lexicon] = [
        build(.war, TopicLexicon.war),
        build(.politics, TopicLexicon.politics),
        build(.economics, TopicLexicon.economics),
    ]

    private static func build(_ topic: Topic, _ terms: [(String, Double)]) -> Lexicon {
        var words: [String: Double] = [:]
        var phrases: [Phrase] = []
        for (term, weight) in terms {
            if let space = term.firstIndex(of: " ") {
                phrases.append(Phrase(text: term,
                                      head: String(term[term.startIndex..<space]),
                                      weight: weight))
            } else {
                // Keep the strongest weight if a term is listed twice — by
                // magnitude, because a weight can be negative and `max` would
                // quietly discard a cancelling term in favour of nothing.
                if let existing = words[term], abs(existing) >= abs(weight) { continue }
                words[term] = weight
            }
        }
        return Lexicon(topic: topic, words: words, phrases: phrases)
    }

    // MARK: - Classification

    static func classify(title: String,
                         body: String,
                         prior: Topic?,
                         fallback: Topic,
                         dropsUnsortable: Bool = false) -> TopicVerdict {
        let titleField = field(title)
        let bodyField = field(bodyPrefix(body))

        var scores: [Topic: Double] = [:]
        var hits: [Topic: [(String, Double)]] = [:]

        for lexicon in lexicons {
            var score = 0.0
            var matched: [(String, Double)] = []

            for (word, weight) in lexicon.words {
                // Distinct terms, not occurrences: a term counts once for the
                // title and once for the body, at most.
                if titleField.words.contains(word) {
                    score += weight * titleWeight
                    matched.append((word, weight * titleWeight))
                } else if bodyField.words.contains(word) {
                    score += weight
                    matched.append((word, weight))
                }
            }

            for phrase in lexicon.phrases {
                // A phrase cannot match unless its first word is present, and
                // checking that is a set lookup rather than a scan of the whole
                // body. Without this gate, classifying one article means ~150
                // substring searches over a 1,400-character string, and a cold
                // launch that classifies four hundred cached articles spends a
                // second doing it before the first row appears.
                let inTitle = titleField.words.contains(phrase.head)
                let inBody = bodyField.words.contains(phrase.head)
                guard inTitle || inBody else { continue }

                if inTitle, titleField.contains(phrase.text) {
                    score += phrase.weight * titleWeight
                    matched.append((phrase.text, phrase.weight * titleWeight))
                } else if inBody, bodyField.contains(phrase.text) {
                    score += phrase.weight
                    matched.append((phrase.text, phrase.weight))
                }
            }

            scores[lexicon.topic] = score
            hits[lexicon.topic] = matched
        }

        // The threshold is tested against the *evidence* alone, before the
        // prior is added. The prior is a belief about the source, not something
        // the story said, so letting it push a total over the line meant a
        // single weak word plus "this outlet is usually politics" counted as
        // having seen something — which is how "University wins the
        // championship" became a politics story.
        let strongest = Topic.classifiable.map { scores[$0] ?? 0 }.max() ?? 0
        guard strongest >= minimumScore else {
            return TopicVerdict(topic: dropsUnsortable ? nil : fallback,
                                confidence: 0, evidence: [], isFallback: true)
        }

        if let prior {
            scores[prior, default: 0] += sourcePriorWeight
        }

        let ranked = Topic.classifiable
            .map { ($0, scores[$0] ?? 0) }
            .sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                // A stable tie-break, so the same article never flips topic
                // between two refreshes.
                return left.0.rawValue < right.0.rawValue
            }

        guard let winner = ranked.first else {
            return TopicVerdict(topic: dropsUnsortable ? nil : fallback,
                                confidence: 0, evidence: [], isFallback: true)
        }

        let runnerUp = ranked.count > 1 ? ranked[1].1 : 0
        let margin = (winner.1 - runnerUp) / winner.1

        let evidence = (hits[winner.0] ?? [])
            .sorted { $0.1 > $1.1 }
            .prefix(4)
            .map(\.0)

        return TopicVerdict(
            topic: winner.0,
            confidence: min(1.0, margin / max(decisiveMargin, 0.0001)),
            evidence: Array(evidence),
            isFallback: false
        )
    }

    // MARK: - Text preparation

    /// Only the opening of the body is scored.
    ///
    /// A full ZeroHedge article runs to thousands of words and drifts through
    /// every topic there is by the end. The first few hundred words are what
    /// the piece is actually about, and bounding it also keeps classification
    /// off the profiler.
    private static func bodyPrefix(_ body: String, limit: Int = 1400) -> String {
        body.count <= limit ? body : String(body.prefix(limit))
    }

    /// One piece of text, prepared for matching two ways.
    ///
    /// Hyphens are the problem this solves. Several terms need them —
    /// "no-fly zone", "f-16", "10-year" — so they cannot simply be flattened
    /// to spaces. But headlines also write "air-strike" and "counter-offensive"
    /// with a hyphen where the lexicon has a space, and keeping the hyphen
    /// means those never match.
    ///
    /// So both spellings are kept: `text` preserves hyphens, `loose` flattens
    /// them, a term matches against either, and the token set is the union. It
    /// is one extra string per article and it fixes a whole class of misses.
    private struct Field {
        let text: String
        let loose: String
        let words: Set<String>

        func contains(_ phrase: String) -> Bool {
            text.contains(phrase) || loose.contains(phrase)
        }
    }

    private static func field(_ raw: String) -> Field {
        let text = normalise(raw)
        guard text.contains("-") else {
            return Field(text: text, loose: text, words: tokens(in: text))
        }
        let loose = normalise(text.replacingOccurrences(of: "-", with: " "))
        return Field(text: text, loose: loose,
                     words: tokens(in: text).union(tokens(in: loose)))
    }

    /// Lowercased, with punctuation flattened to spaces.
    ///
    /// Apostrophes become spaces rather than being deleted. Deleting them turns
    /// "Powell's" into "powells", which matches nothing — the possessive has to
    /// break into "powell" and a stray "s" for the term to land.
    static func normalise(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count + 2)

        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "&" {
                out.append(scalar)
            } else {
                out.append(" ")
            }
        }
        // Collapse the runs the substitution just created, so a phrase written
        // with single spaces still matches text that had punctuation in it.
        return String(out).split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    static func tokens(in normalised: String) -> Set<String> {
        Set(normalised.split(separator: " ").map(String.init))
    }
}

extension Article {

    /// The topic this article belongs to, resolved once and cached on the
    /// article so scrolling does not re-score every visible row.
    func classified(using source: Source?) -> TopicVerdict {
        guard let source else {
            return TopicVerdict(topic: .politics, confidence: 0, evidence: [], isFallback: true)
        }

        switch source.topicMode {
        case .fixed:
            return TopicVerdict(topic: source.fixedTopic, confidence: 1,
                                evidence: [], isFallback: false)
        case .classified:
            return TopicClassifier.classify(
                title: displayTitle,
                body: summary,
                prior: source.topicPrior,
                fallback: source.fixedTopic,
                dropsUnsortable: source.dropsUnsortable
            )
        }
    }
}
