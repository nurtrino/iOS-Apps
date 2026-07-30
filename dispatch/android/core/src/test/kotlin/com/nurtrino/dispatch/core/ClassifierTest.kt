package com.nurtrino.dispatch.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The classifier, against the same corpus the iOS suite uses.
 *
 * The lexicon is generated from the Swift by `tools/gen_lexicon_kt.py`, so these
 * run against the table the other app ships. Both apps reading the same feeds and
 * filing the same story differently would be a bug nobody would ever notice, and
 * this is what stops it.
 */
class ClassifierTest {

    private fun topicOf(title: String, body: String = "", prior: Topic? = null,
                        fallback: Topic = Topic.POLITICS): Topic? =
        TopicClassifier.classify(title, body, prior, fallback).topic

    private fun sawNothing(title: String, prior: Topic? = Topic.POLITICS): Boolean =
        TopicClassifier.classify(title, "", prior, Topic.POLITICS).isFallback

    @Test
    fun `the generated lexicon is substantial`() {
        assertTrue(TopicLexicon.war.size > 100)
        assertTrue(TopicLexicon.politics.size > 100)
        assertTrue(TopicLexicon.economics.size > 100)
    }

    @Test
    fun `negative weights survive generation`() =
        assertTrue(TopicLexicon.economics.any { it.second < 0 })

    // --- The words that belong to two topics --------------------------------

    @Test
    fun `an air strike is war, not a labour dispute`() =
        assertEquals(Topic.WAR, topicOf("Air strike destroys ammunition depot near Donetsk"))

    @Test
    fun `a strike authorization is economics`() =
        assertEquals(
            Topic.ECONOMICS,
            topicOf("Autoworkers vote to authorize strike at three plants", prior = Topic.ECONOMICS),
        )

    @Test
    fun `the West Bank is war, not banking`() =
        assertEquals(Topic.WAR, topicOf("West Bank raid leaves several dead"))

    @Test
    fun `a central bank is economics`() =
        assertEquals(
            Topic.ECONOMICS,
            topicOf("Central bank holds rates as inflation cools", prior = Topic.ECONOMICS),
        )

    @Test
    fun `a campaign rally is not a market rally`() =
        assertEquals(
            Topic.POLITICS,
            topicOf("Thousands turn out for campaign rally in Ohio", prior = Topic.POLITICS),
        )

    @Test
    fun `tariffs are economics even on a political outlet`() =
        assertEquals(
            Topic.ECONOMICS,
            topicOf("Trump announces new tariffs on Chinese imports", prior = Topic.POLITICS),
        )

    // --- The other sense of a word ------------------------------------------

    @Test
    fun `winning gold at the Olympics scores as nothing`() =
        assertTrue(sawNothing("Man wins gold at the Olympics"))

    @Test
    fun `but gold itself still scores`() =
        assertEquals(Topic.ECONOMICS, topicOf("Gold hits record high", prior = Topic.POLITICS))

    @Test
    fun `a price war is not a war`() = assertTrue(sawNothing("Price war breaks out among airlines"))

    @Test
    fun `a film bombing is not a war story`() =
        assertTrue(sawNothing("Film bombs at the box office"))

    @Test
    fun `a hike on a trail is not a rate hike`() =
        assertTrue(sawNothing("Hikes on the Appalachian Trail get busier"))

    /** The prior is a belief about the source, not something the story said. */
    @Test
    fun `the prior cannot get a story over the line`() =
        assertTrue(sawNothing("University wins college football championship"))

    // --- Weighting -----------------------------------------------------------

    @Test
    fun `the headline outweighs the body`() =
        assertEquals(
            Topic.WAR,
            topicOf(
                "Missile strike on Kharkiv",
                body = "Traders said the stock market and inflation outlook were unchanged.",
                prior = Topic.ECONOMICS,
            ),
        )

    @Test
    fun `the source prior cannot override a strong signal`() =
        assertEquals(
            Topic.WAR,
            topicOf("Artillery duel intensifies along the frontline", prior = Topic.ECONOMICS),
        )

    /** The lexicon never hides a story, whatever the source is set to. */
    @Test
    fun `the lexicon always names a section`() =
        assertEquals(Topic.POLITICS, topicOf("Recipe: the only pie crust you need"))

    @Test
    fun `and admits it was guessing`() = assertTrue(sawNothing("Recipe: the only pie crust you need"))

    // --- Normalisation --------------------------------------------------------

    @Test
    fun `case is ignored`() = assertEquals(Topic.WAR, topicOf("AIRSTRIKE ON KYIV"))

    /** Deleting the apostrophe turns "Powell's" into "powells", which matches nothing. */
    @Test
    fun `an apostrophe does not break a term`() =
        assertEquals(
            Topic.ECONOMICS,
            topicOf("Powell's testimony moves markets", prior = Topic.ECONOMICS),
        )

    @Test
    fun `a hyphen does not break a phrase`() =
        assertEquals(Topic.WAR, topicOf("Report: air-strike hits depot"))

    @Test
    fun `normalisation collapses whitespace`() =
        assertEquals("air strike on kyiv", TopicClassifier.normalise("  Air   strike\non   Kyiv  "))

    @Test
    fun `normalisation keeps hyphens and ampersands`() =
        assertEquals("s&p 500 and the 10-year", TopicClassifier.normalise("S&P 500 and the 10-year"))

    // --- The corpus -----------------------------------------------------------
    //
    // A sample of the aggregator corpus from the Python suite. The full 73 live
    // there; these are the ones that were misfiled or invisible at some point.

    @Test
    fun `the corpus files where it belongs`() {
        val corpus = listOf(
            Triple("Massive explosion reported in Riyadh", Topic.POLITICS, Topic.WAR),
            Triple("Illegal alien charged with murder in Texas", Topic.POLITICS, Topic.POLITICS),
            Triple("ICE arrests 200 in weekend sweep", Topic.POLITICS, Topic.POLITICS),
            Triple("Egg prices spike again", Topic.POLITICS, Topic.ECONOMICS),
            Triple("Netanyahu vows response", Topic.POLITICS, Topic.WAR),
            Triple("CNN ratings hit new low", Topic.POLITICS, Topic.POLITICS),
            Triple("Social Security COLA announced", Topic.POLITICS, Topic.ECONOMICS),
            Triple("Convoy ambushed outside Kabul", Topic.POLITICS, Topic.WAR),
            Triple("School board votes to remove books", Topic.POLITICS, Topic.POLITICS),
            Triple("Dollar slides to two-year low", Topic.POLITICS, Topic.ECONOMICS),
        )
        val wrong = corpus.filter { (title, prior, want) ->
            topicOf(title, prior = prior, fallback = prior) != want
        }
        assertEquals(emptyList<Triple<String, Topic, Topic>>(), wrong)
    }
}

/**
 * The Claude request and reply, which are pure string handling and therefore the
 * parts that fail silently.
 */
class ClaudeApiTest {

    @Test
    fun `the model is the cheap one`() = assertEquals("claude-haiku-4-5", ClaudeApi.MODEL)

    @Test
    fun `the filing prompt numbers from one`() =
        assertEquals(
            "1. Gold hits record high\n2. Israel strikes Gaza",
            ClaudeApi.filingPrompt(listOf("Gold hits record high", "Israel strikes Gaza")),
        )

    /** A headline with a newline in it would break the numbering it sits in. */
    @Test
    fun `a multi-line headline is flattened`() =
        assertEquals("Breaking: explosion reported", ClaudeApi.oneLine("Breaking:\nexplosion reported"))

    @Test
    fun `the plain reply format parses`() =
        assertEquals(
            mapOf(1 to ClaudeApi.Decision.Section(Topic.WAR),
                  2 to ClaudeApi.Decision.Section(Topic.POLITICS)),
            ClaudeApi.parseDecisions("1 war\n2 politics"),
        )

    @Test
    fun `the shapes a model actually returns all parse`() {
        assertEquals(mapOf(1 to ClaudeApi.Decision.Section(Topic.WAR)),
            ClaudeApi.parseDecisions("1. war"))
        assertEquals(mapOf(2 to ClaudeApi.Decision.Section(Topic.ECONOMICS)),
            ClaudeApi.parseDecisions("2) economics"))
        assertEquals(mapOf(3 to ClaudeApi.Decision.Section(Topic.GAMING)),
            ClaudeApi.parseDecisions("3 - gaming"))
        assertEquals(mapOf(6 to ClaudeApi.Decision.Section(Topic.POLITICS)),
            ClaudeApi.parseDecisions("6 Politics"))
        assertEquals(mapOf(40 to ClaudeApi.Decision.Section(Topic.ECONOMICS)),
            ClaudeApi.parseDecisions("40 economics"))
    }

    /** "Nowhere" is a decision. Not answering is not, and only one hides a story. */
    @Test
    fun `none is a decision`() =
        assertEquals(mapOf(7 to ClaudeApi.Decision.Unplaced), ClaudeApi.parseDecisions("7 none"))

    @Test
    fun `preamble and prose are ignored`() {
        assertEquals(mapOf(1 to ClaudeApi.Decision.Section(Topic.WAR)),
            ClaudeApi.parseDecisions("Sure, here are the sections:\n1 war"))
        assertEquals(emptyMap<Int, ClaudeApi.Decision>(), ClaudeApi.parseDecisions("1 sport"))
        assertEquals(emptyMap<Int, ClaudeApi.Decision>(), ClaudeApi.parseDecisions("war"))
        assertEquals(emptyMap<Int, ClaudeApi.Decision>(), ClaudeApi.parseDecisions(""))
    }

    // --- The brief ------------------------------------------------------------

    @Test
    fun `plain lines become bullets`() =
        assertEquals(
            listOf("Riyadh airport closes overnight", "US tankers over the Gulf"),
            ClaudeApi.bullets("Riyadh airport closes overnight\nUS tankers over the Gulf"),
        )

    @Test
    fun `markers a model adds are stripped`() {
        assertEquals(listOf("First", "Second"), ClaudeApi.bullets("- First\n- Second"))
        assertEquals(listOf("First", "Second"), ClaudeApi.bullets("1. First\n2) Second"))
        assertEquals(listOf("CPI at 3.4%"), ClaudeApi.bullets("**CPI** at 3.4%"))
    }

    /** Eating the "3." here would print "4% and rising". */
    @Test
    fun `a leading decimal survives`() =
        assertEquals(listOf("3.4% and rising"), ClaudeApi.bullets("3.4% and rising"))

    // --- JSON by hand ---------------------------------------------------------

    @Test
    fun `quotes and newlines are escaped`() =
        assertEquals("""a\"b\nc""", ClaudeApi.escape("a\"b\nc"))

    @Test
    fun `a body round-trips through the escaper`() {
        val body = ClaudeApi.requestBody("system \"quoted\"", "user\nlines", 300)
        assertTrue(body.contains(""""model":"claude-haiku-4-5""""))
        assertTrue(body.contains("""\"quoted\""""))
        assertTrue(body.contains("""user\nlines"""))
    }

    @Test
    fun `text blocks come out of a response`() =
        assertEquals(
            "1 war\n2 politics",
            ClaudeApi.extractText(
                """{"content":[{"type":"text","text":"1 war\n2 politics"}],"stop_reason":"end_turn"}""",
            ),
        )

    /** A refusal is a terminal state, not an empty answer. */
    @Test
    fun `a refusal returns null`() =
        assertEquals(
            null,
            ClaudeApi.extractText("""{"content":[],"stop_reason":"refusal"}"""),
        )
}
