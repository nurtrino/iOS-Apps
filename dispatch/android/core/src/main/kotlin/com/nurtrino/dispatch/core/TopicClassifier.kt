package com.nurtrino.dispatch.core

/** What the classifier decided, and how sure it was. */
data class TopicVerdict(
    /**
     * Where the story goes, or null when it goes nowhere.
     *
     * Only the model ever returns null. The lexicon always names a section,
     * falling back to the source's default when it saw nothing, because a lexicon
     * that hides what it does not recognise turns every missing term into a
     * missing story.
     */
    val topic: Topic?,
    val confidence: Double,
    val evidence: List<String>,
    val isFallback: Boolean,
    val decidedByModel: Boolean = false,
)

/**
 * Sorts a story into War, Politics or Markets — a port of the iOS classifier,
 * scoring against the same generated lexicon so both apps file a story the same
 * way.
 *
 * Three things make it better than a naive keyword match: phrases outrank words
 * (a labour strike and an air strike are different sections), the headline counts
 * for more than the body, and distinct terms are counted rather than occurrences.
 */
object TopicClassifier {

    const val TITLE_WEIGHT = 2.2
    const val MINIMUM_SCORE = 3.0
    const val DECISIVE_MARGIN = 0.35
    const val SOURCE_PRIOR_WEIGHT = 1.25

    private class Phrase(val text: String, val head: String, val weight: Double)
    private class Lexicon(val topic: Topic, val words: Map<String, Double>, val phrases: List<Phrase>)

    private val lexicons: List<Lexicon> by lazy {
        listOf(
            build(Topic.WAR, TopicLexicon.war),
            build(Topic.POLITICS, TopicLexicon.politics),
            build(Topic.ECONOMICS, TopicLexicon.economics),
        )
    }

    private fun build(topic: Topic, terms: List<Pair<String, Double>>): Lexicon {
        val words = HashMap<String, Double>()
        val phrases = ArrayList<Phrase>()
        for ((term, weight) in terms) {
            val space = term.indexOf(' ')
            if (space >= 0) {
                phrases.add(Phrase(term, term.substring(0, space), weight))
            } else {
                // By magnitude, because a weight can be negative and taking the
                // maximum would quietly discard a cancelling term in favour of
                // nothing.
                val existing = words[term]
                if (existing == null || kotlin.math.abs(weight) > kotlin.math.abs(existing)) {
                    words[term] = weight
                }
            }
        }
        return Lexicon(topic, words, phrases)
    }

    fun classify(title: String, body: String, prior: Topic?, fallback: Topic): TopicVerdict {
        val titleField = field(title)
        val bodyField = field(body.take(1400))

        val scores = HashMap<Topic, Double>()
        val hits = HashMap<Topic, MutableList<Pair<String, Double>>>()

        for (lexicon in lexicons) {
            var score = 0.0
            val matched = ArrayList<Pair<String, Double>>()

            for ((word, weight) in lexicon.words) {
                if (titleField.words.contains(word)) {
                    score += weight * TITLE_WEIGHT
                    matched.add(word to weight * TITLE_WEIGHT)
                } else if (bodyField.words.contains(word)) {
                    score += weight
                    matched.add(word to weight)
                }
            }

            for (phrase in lexicon.phrases) {
                // A phrase cannot match unless its first word is present, and
                // checking that is a set lookup rather than a scan of the body.
                val inTitle = titleField.words.contains(phrase.head)
                val inBody = bodyField.words.contains(phrase.head)
                if (!inTitle && !inBody) continue

                if (inTitle && titleField.contains(phrase.text)) {
                    score += phrase.weight * TITLE_WEIGHT
                    matched.add(phrase.text to phrase.weight * TITLE_WEIGHT)
                } else if (inBody && bodyField.contains(phrase.text)) {
                    score += phrase.weight
                    matched.add(phrase.text to phrase.weight)
                }
            }

            scores[lexicon.topic] = score
            hits[lexicon.topic] = matched
        }

        // The threshold is tested against the evidence alone, before the prior is
        // added: the prior is a belief about the source, not something the story
        // said, and letting it push a total over the line meant one weak word plus
        // "this outlet is usually politics" counted as having seen something.
        val strongest = Topic.classifiable.maxOf { scores[it] ?: 0.0 }
        if (strongest < MINIMUM_SCORE) {
            return TopicVerdict(fallback, 0.0, emptyList(), isFallback = true)
        }

        if (prior != null) {
            scores[prior] = (scores[prior] ?: 0.0) + SOURCE_PRIOR_WEIGHT
        }

        val ranked = Topic.classifiable
            .map { it to (scores[it] ?: 0.0) }
            // A stable tie-break, so the same article never flips topic between
            // two refreshes.
            .sortedWith(compareByDescending<Pair<Topic, Double>> { it.second }.thenBy { it.first.id })

        val winner = ranked.first()
        val runnerUp = if (ranked.size > 1) ranked[1].second else 0.0
        val margin = (winner.second - runnerUp) / winner.second

        val evidence = (hits[winner.first] ?: emptyList())
            .sortedByDescending { it.second }
            .take(4)
            .map { it.first }

        return TopicVerdict(
            topic = winner.first,
            confidence = minOf(1.0, margin / DECISIVE_MARGIN),
            evidence = evidence,
            isFallback = false,
        )
    }

    /**
     * One piece of text, prepared for matching two ways.
     *
     * Hyphens are the problem this solves. Several terms need them — "no-fly
     * zone", "f-16", "10-year" — so they cannot simply be flattened. But headlines
     * also write "air-strike" where the lexicon has "air strike". Both spellings
     * are kept and the token set is the union.
     */
    private class Field(val text: String, val loose: String, val words: Set<String>) {
        fun contains(phrase: String) = text.contains(phrase) || loose.contains(phrase)
    }

    private fun field(raw: String): Field {
        val text = normalise(raw)
        if (!text.contains('-')) return Field(text, text, tokens(text))
        val loose = normalise(text.replace('-', ' '))
        return Field(text, loose, tokens(text) + tokens(loose))
    }

    /**
     * Lowercased, with punctuation flattened to spaces.
     *
     * Apostrophes become spaces rather than being deleted: deleting them turns
     * "Powell's" into "powells", which matches nothing.
     */
    fun normalise(text: String): String {
        val out = StringBuilder(text.length + 2)
        for (character in text.lowercase()) {
            if (character.isLetterOrDigit() || character == '-' || character == '&') {
                out.append(character)
            } else {
                out.append(' ')
            }
        }
        return out.toString().split(' ').filter { it.isNotEmpty() }.joinToString(" ")
    }

    fun tokens(normalised: String): Set<String> =
        normalised.split(' ').filter { it.isNotEmpty() }.toSet()
}
