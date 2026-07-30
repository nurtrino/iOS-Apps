package com.nurtrino.dispatch.core

/**
 * The Claude API, for the two things it does in this app: filing stories into
 * sections, and writing the brief.
 *
 * Raw HTTP rather than an SDK — the same choice as iOS, for the same reason on
 * the other side of it: adding a dependency to send one JSON document is not a
 * trade worth making, and the request shape is identical on both platforms.
 *
 * Everything in here except `post` is a pure function, which is why it lives in
 * `core`: the prompt building and the reply parsing are the parts that break
 * silently, and they are tested on the JVM rather than on a device.
 */
object ClaudeApi {

    const val ENDPOINT = "https://api.anthropic.com/v1/messages"
    const val API_VERSION = "2023-06-01"

    /**
     * Haiku, deliberately. Filing a headline and writing four lines off headlines
     * that are already written are both small jobs, they run all day, and this is
     * a fifth of the price of an Opus.
     */
    const val MODEL = "claude-haiku-4-5"

    const val CLASSIFY_BATCH = 40
    const val CLASSIFY_MAX_TOKENS = 600
    const val SUMMARY_MAX_TOKENS = 300

    // MARK: - Filing

    val FILING_SYSTEM_PROMPT = buildString {
        append("You file news headlines into one section of a personal news app. The sections are:\n")
        append("war — armed conflict, militaries, defence, strikes, foreign crises and the ")
        append("countries in them\n")
        append("politics — government, elections, courts, crime, policing, immigration, ")
        append("protest, culture and the press\n")
        append("economics — markets, prices, the cost of living, the Fed, jobs, business\n")
        append("gaming — video games\n")
        append("none — belongs to no section: sport, celebrity, weather, animals, recipes, ")
        append("viral video, human interest\n\n")
        append("Most headlines belong to a section. Use none only when a reader looking for ")
        append("news would not want it in any of the four. When a headline could fit two, pick ")
        append("the one a reader would look for it under.\n\n")
        append("Reply with one line per headline: the headline's number, a space, then one word ")
        append("from war, politics, economics, gaming, none. No other text.")
    }

    /** A headline has to be one line, or the numbering stops meaning anything. */
    fun oneLine(title: String): String =
        title.replace('\n', ' ').replace('\r', ' ')
            .split(' ').filter { it.isNotEmpty() }.joinToString(" ")
            .take(200)

    fun filingPrompt(titles: List<String>): String =
        titles.mapIndexed { index, title -> "${index + 1}. ${oneLine(title)}" }
            .joinToString("\n")

    /** The model's answer for one headline: a section, or nowhere. */
    sealed interface Decision {
        data class Section(val topic: Topic) : Decision
        data object Unplaced : Decision
    }

    private val SEPARATORS = " .):-–—\t,"

    /**
     * Parses the reply into decisions by line number.
     *
     * Tolerant on purpose. The format asked for is "3 politics", and what comes
     * back is sometimes "3. politics", "3) Politics" or "3 - politics". A line that
     * cannot be read is left out rather than guessed at, and a missing number keeps
     * whatever the lexicon already decided.
     */
    fun parseDecisions(text: String): Map<Int, Decision> {
        val out = HashMap<Int, Decision>()
        for (raw in text.split('\n')) {
            val line = raw.trim().lowercase()
            if (line.isEmpty()) continue

            var index = 0
            while (index < line.length && line[index].isDigit()) index++
            val number = line.substring(0, index).toIntOrNull() ?: continue

            while (index < line.length && SEPARATORS.contains(line[index])) index++
            val start = index
            while (index < line.length && line[index].isLetter()) index++
            val word = line.substring(start, index)

            val decision = when (word) {
                "none" -> Decision.Unplaced
                else -> Topic.from(word)?.let { Decision.Section(it) }
            }
            if (decision != null) out[number] = decision
        }
        return out
    }

    // MARK: - The brief

    val SUMMARY_SYSTEM_PROMPT = buildString {
        append("You write the brief at the top of a section in a personal news app. ")
        append("Given the newest headlines, write two to four short lines covering what just ")
        append("happened, most consequential first, so the reader knows the state of things ")
        append("before scanning the list. ")
        append("One line per point, separated by newlines. Each line is a single clause or ")
        append("short sentence under about twenty words. ")
        append("Where several headlines are the same story, merge them into one line. ")
        append("Keep concrete numbers, names and places from the headlines; never add facts ")
        append("the headlines do not contain. ")
        append("No bullet characters, no numbering, no markdown, no preamble — just the lines.")
    }

    class Headline(val title: String, val source: String, val age: String?)

    fun summaryPrompt(topic: String, headlines: List<Headline>): String {
        val lines = ArrayList<String>()
        lines.add("Section: $topic")
        lines.add("Headlines, newest first:")
        for (headline in headlines) {
            val age = headline.age?.let { ", $it" } ?: ""
            lines.add("- [${headline.source}$age] ${headline.title}")
        }
        return lines.joinToString("\n")
    }

    /**
     * Splits a generated brief into the lines the section renders as bullets.
     *
     * The prompt asks for no bullet characters and mostly gets it, but a model that
     * decides to be helpful and prefixes every line must not produce a screen of
     * double bullets.
     */
    fun bullets(text: String): List<String> {
        val out = ArrayList<String>()
        for (raw in text.split('\n')) {
            var line = raw.replace("**", "").trim()
            line = stripMarker(stripMarker(line))
            if (line.length > 1) out.add(line)
        }
        return out
    }

    private fun stripMarker(line: String): String {
        if (line.isEmpty()) return line
        if ("-–—*•·".contains(line[0])) return line.substring(1).trim()
        if (!line[0].isDigit()) return line

        // "1. " is a marker. "3.4% inflation" is not, which is why the digits have
        // to be followed by a separator *and* a space.
        var index = 0
        while (index < line.length && line[index].isDigit() && index < 2) index++
        if (index >= line.length || (line[index] != '.' && line[index] != ')')) return line
        if (index + 1 >= line.length || line[index + 1] != ' ') return line
        return line.substring(index + 1).trim()
    }

    // MARK: - Request bodies

    /**
     * Built by hand rather than with a JSON library.
     *
     * `core` has no dependencies, and the bodies are three keys and a string. What
     * a library would buy is escaping, so that is the one part done carefully.
     */
    fun requestBody(system: String, user: String, maxTokens: Int): String =
        """{"max_tokens":$maxTokens,"messages":[{"content":"${escape(user)}","role":"user"}],""" +
            """"model":"$MODEL","system":"${escape(system)}"}"""

    fun escape(text: String): String {
        val out = StringBuilder(text.length + 16)
        for (character in text) {
            when (character) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                else -> if (character.code < 0x20) {
                    out.append("\\u%04x".format(character.code))
                } else {
                    out.append(character)
                }
            }
        }
        return out.toString()
    }

    /**
     * The text blocks of a Messages API response.
     *
     * Hand-parsed for the same reason as above, and narrowly: find each
     * `"text":"..."` inside the content array and unescape it. A refusal is
     * reported as a null return so the caller can tell it from an error.
     */
    fun extractText(json: String): String? {
        if (json.contains("\"stop_reason\":\"refusal\"")) return null
        val out = StringBuilder()
        var index = 0
        val marker = "\"text\":\""
        while (true) {
            val start = json.indexOf(marker, index)
            if (start < 0) break
            var cursor = start + marker.length
            val block = StringBuilder()
            while (cursor < json.length) {
                val character = json[cursor]
                if (character == '\\' && cursor + 1 < json.length) {
                    when (val escaped = json[cursor + 1]) {
                        'n' -> block.append('\n')
                        'r' -> block.append('\r')
                        't' -> block.append('\t')
                        'u' -> {
                            val code = json.substring(cursor + 2, cursor + 6).toIntOrNull(16)
                            if (code != null) block.append(code.toChar())
                            cursor += 4
                        }
                        else -> block.append(escaped)
                    }
                    cursor += 2
                    continue
                }
                if (character == '"') break
                block.append(character)
                cursor++
            }
            out.append(block)
            index = cursor
        }
        return out.toString().ifEmpty { null }
    }
}
