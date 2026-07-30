package com.nurtrino.dispatch.core

import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * The date formats feeds actually use.
 *
 * An unparsed date sorts to the bottom of a merged feed, so a source with an
 * unhandled format looks like it stopped updating rather than like a bug.
 */
object DateParsing {

    private val PATTERNS = listOf(
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss z",
        "EEE, dd MMM yyyy HH:mm Z",
        "dd MMM yyyy HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ssXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXX",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd",
    )

    private val FORMATTERS = PATTERNS.map {
        DateTimeFormatter.ofPattern(it, Locale.US).withZone(ZoneOffset.UTC)
    }

    fun parse(text: String?): Long? {
        val trimmed = text?.trim()?.takeIf { it.isNotEmpty() } ?: return null

        // GMT is not a zone abbreviation every parser knows, and "UT" appears in
        // older feeds. Both mean the same thing here.
        val normalised = trimmed
            .replace(" GMT", " +0000")
            .replace(" UT", " +0000")
            .replace("Z", "+00:00")
            .let { if (it.endsWith("+00:00+00:00")) it.dropLast(6) else it }

        for (formatter in FORMATTERS) {
            try {
                return OffsetDateTime.parse(normalised, formatter).toInstant().toEpochMilli()
            } catch (_: Exception) {
                try {
                    val local = java.time.LocalDateTime.parse(normalised, formatter)
                    return local.toInstant(ZoneOffset.UTC).toEpochMilli()
                } catch (_: Exception) {
                    try {
                        val date = java.time.LocalDate.parse(normalised, formatter)
                        return date.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
                    } catch (_: Exception) {
                        continue
                    }
                }
            }
        }
        return try {
            Instant.parse(trimmed).toEpochMilli()
        } catch (_: Exception) {
            null
        }
    }

    /** "4m", "3h", "2d" — the compact form a scannable feed wants. */
    fun age(published: Long, now: Long = System.currentTimeMillis()): String {
        val seconds = (now - published) / 1000
        return when {
            seconds < 60 -> "now"
            seconds < 3600 -> "${seconds / 60}m"
            seconds < 86_400 -> "${seconds / 3600}h"
            seconds < 604_800 -> "${seconds / 86_400}d"
            else -> DateTimeFormatter.ofPattern("d MMM", Locale.getDefault())
                .withZone(ZoneOffset.systemDefault())
                .format(Instant.ofEpochMilli(published))
        }
    }
}
