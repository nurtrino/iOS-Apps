package com.nurtrino.dispatch.core

enum class SourceKind { RSS, TELEGRAM, STEAM }

enum class SourceStyle { ARTICLE, WIRE }

/** Whether a source's topic is known up front or worked out per item. */
enum class TopicMode { FIXED, CLASSIFIED }

data class Source(
    val id: String,
    val name: String,
    val kind: SourceKind = SourceKind.RSS,
    val endpoint: String,
    val topicMode: TopicMode = TopicMode.FIXED,
    /** Also the classifier's fallback when nothing scores. */
    val fixedTopic: Topic = Topic.POLITICS,
    val topicPrior: Topic? = null,
    val fallbackFeeds: List<String> = emptyList(),
    val style: SourceStyle = SourceStyle.ARTICLE,
    /** Skip the reader and open the publisher's page — right for an aggregator. */
    val prefersWebPage: Boolean = false,
    /** Follow the permalink through to the article it points at. */
    val resolvesOutboundLink: Boolean = false,
    /** Let the model drop a story it judges to belong in no section. */
    val dropsUnsortable: Boolean = false,
    val isEnabled: Boolean = true,
) {
    val reachableTopics: List<Topic>
        get() = if (topicMode == TopicMode.FIXED) listOf(fixedTopic) else Topic.classifiable
}

/** The sources the app ships with — the same set as iOS. */
object SourceCatalog {

    val defaults: List<Source> = listOf(
        Source(
            id = "zerohedge",
            name = "ZeroHedge",
            endpoint = "https://feeds.feedburner.com/zerohedge/feed",
            topicMode = TopicMode.CLASSIFIED,
            fixedTopic = Topic.ECONOMICS,
            topicPrior = Topic.ECONOMICS,
            fallbackFeeds = listOf("https://www.zerohedge.com/fullrss2.xml"),
        ),
        Source(
            id = "citizenfreepress",
            name = "Citizen Free Press",
            endpoint = "https://citizenfreepress.com/feed/",
            topicMode = TopicMode.CLASSIFIED,
            fixedTopic = Topic.POLITICS,
            topicPrior = Topic.POLITICS,
            fallbackFeeds = listOf("https://citizenfreepress.com/feed/rss/"),
            style = SourceStyle.WIRE,
            prefersWebPage = true,
            resolvesOutboundLink = true,
            dropsUnsortable = true,
        ),
        Source(
            id = "twz",
            name = "The War Zone",
            endpoint = "https://www.twz.com/feed",
            fixedTopic = Topic.WAR,
            fallbackFeeds = listOf("https://www.twz.com/rss"),
        ),
        Source(
            id = "charlieintel-rss",
            name = "CharlieIntel",
            endpoint = "https://www.charlieintel.com/feed/",
            fixedTopic = Topic.GAMING,
            style = SourceStyle.WIRE,
        ),
        Source(
            id = "gematsu",
            name = "Gematsu",
            endpoint = "https://www.gematsu.com/feed",
            fixedTopic = Topic.GAMING,
            style = SourceStyle.WIRE,
        ),
        Source(
            id = "vgc",
            name = "Video Games Chronicle",
            endpoint = "https://www.videogameschronicle.com/feed/",
            fixedTopic = Topic.GAMING,
            style = SourceStyle.WIRE,
        ),
        Source(
            id = "pcgamer",
            name = "PC Gamer",
            endpoint = "https://www.pcgamer.com/rss/",
            fixedTopic = Topic.GAMING,
            style = SourceStyle.WIRE,
        ),
    )

    fun default(id: String): Source? = defaults.firstOrNull { it.id == id }
}
