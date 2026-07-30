package com.nurtrino.dispatch

import android.content.Context
import com.nurtrino.dispatch.core.Article
import com.nurtrino.dispatch.core.ClaudeApi
import com.nurtrino.dispatch.core.FeedParser
import com.nurtrino.dispatch.core.HtmlText
import com.nurtrino.dispatch.core.Source
import com.nurtrino.dispatch.core.SourceCatalog
import com.nurtrino.dispatch.core.Topic
import com.nurtrino.dispatch.core.TopicClassifier
import com.nurtrino.dispatch.core.TopicMode
import com.nurtrino.dispatch.core.TopicVerdict
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext

/**
 * Fetching, filing and holding the articles.
 *
 * The iOS app splits this across a FeedStore, a SourceLoader and an HTTP actor;
 * here it is one class, because the Android side has no per-source screens yet
 * and three files would be ceremony. The behaviours that were learned the hard
 * way are all carried over, and each is commented where it lives.
 */
class FeedRepository(context: Context) {

    private val cacheDirectory = File(context.filesDir, "feeds").apply { mkdirs() }
    private val decisionsFile = File(context.filesDir, "model-verdicts.txt")

    /** Articles by source id, and where each one was filed. */
    private val articlesBySource = LinkedHashMap<String, List<Article>>()
    private val verdicts = HashMap<String, TopicVerdict>()

    /** What the model decided, by article id, kept so nothing is paid for twice. */
    private val modelDecisions = HashMap<String, String>()

    /** How many articles one source keeps once its feed has moved on. */
    private val retained = 120

    val sources: List<Source> get() = SourceCatalog.defaults.filter { it.isEnabled }

    init {
        loadDecisions()
    }

    // MARK: - Reading

    fun articles(topic: Topic): List<Article> {
        val seen = HashSet<String>()
        val merged = ArrayList<Article>()
        for (source in sources) {
            for (article in articlesBySource[source.id].orEmpty()) {
                if (verdicts[article.id]?.topic != topic) continue
                // Source order decides which copy of a cross-posted story wins.
                if (!seen.add(article.dedupeKey)) continue
                merged.add(article)
            }
        }
        return merged.sortedWith(compareByDescending<Article> { it.sortDate }.thenBy { it.id })
    }

    fun verdict(article: Article): TopicVerdict? = verdicts[article.id]

    fun sourceName(id: String): String = SourceCatalog.default(id)?.name ?: "Dispatch"

    // MARK: - Loading

    /** The last good copy of every feed, so a cold launch shows news not spinners. */
    fun hydrate() {
        for (source in sources) {
            val file = File(cacheDirectory, source.id + ".xml")
            if (!file.exists()) continue
            runCatching {
                val articles = parse(file.readBytes(), source, null)
                articlesBySource[source.id] = articles
                classify(articles, source)
            }
        }
    }

    suspend fun refresh(): Unit = coroutineScope {
        sources.map { source ->
            async(Dispatchers.IO) {
                runCatching { load(source) }
                    .onSuccess { articles ->
                        // Merged rather than replaced. A feed is a window, not an
                        // archive: an aggregator publishes dozens of items a day
                        // and its RSS holds a fraction of them, so replacing the
                        // list loses everything that came and went between two
                        // refreshes.
                        val merged = merge(articles, articlesBySource[source.id].orEmpty())
                        synchronized(this@FeedRepository) {
                            articlesBySource[source.id] = merged
                            classify(merged, source)
                        }
                    }
            }
        }.awaitAll()
    }

    private fun load(source: Source): List<Article> {
        val candidates = listOf(source.endpoint) + source.fallbackFeeds
        var lastError: Exception? = null
        for ((index, candidate) in candidates.withIndex()) {
            try {
                val bytes = fetch(candidate)
                // Only the primary's payload is cached, so a fallback's contents
                // never become the thing a cold launch shows as if it were normal.
                if (index == 0) {
                    File(cacheDirectory, source.id + ".xml").writeBytes(bytes)
                }
                return parse(bytes, source, if (index == 0) null else HtmlText.hostOf(candidate))
            } catch (error: Exception) {
                lastError = error
            }
        }
        throw lastError ?: IllegalStateException("no feed address for ${source.id}")
    }

    private fun parse(bytes: ByteArray, source: Source, context: String?): List<Article> {
        val feed = FeedParser.parse(bytes)
        val articles = feed.items.map { it.toArticle(source.id, feed.siteLink, context) }

        if (!source.resolvesOutboundLink) return articles

        // An aggregator's own description carries the outbound anchor. Taking it
        // here means the common case never needs a per-tap fetch, and the id was
        // already derived from the permalink so rewriting the link is safe.
        return articles.map { article ->
            val body = article.bodyHtml ?: return@map article
            val permalink = article.link ?: return@map article
            val outbound = HtmlText.outboundLink(body, HtmlText.hostOf(permalink))
            if (outbound != null) article.copy().apply { link = outbound } else article
        }
    }

    private fun merge(incoming: List<Article>, existing: List<Article>): List<Article> {
        if (existing.isEmpty()) return incoming
        val byId = LinkedHashMap<String, Article>()
        // Incoming first, so a re-fetch's corrected title or resolved link wins.
        for (article in incoming + existing) byId.putIfAbsent(article.id, article)
        return byId.values
            .sortedWith(compareByDescending<Article> { it.sortDate }.thenBy { it.id })
            .take(retained)
    }

    private fun fetch(address: String): ByteArray {
        val connection = URL(address).openConnection() as HttpURLConnection
        // The default user agent gets a 403 from Cloudflare in front of a
        // WordPress install, which is a meaningful share of news hosts.
        connection.setRequestProperty("User-Agent", USER_AGENT)
        connection.setRequestProperty(
            "Accept",
            "application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.8",
        )
        connection.connectTimeout = 20_000
        connection.readTimeout = 20_000
        connection.instanceFollowRedirects = true
        try {
            if (connection.responseCode !in 200..299) {
                throw IllegalStateException("HTTP ${connection.responseCode}")
            }
            return connection.inputStream.readBytes()
        } finally {
            connection.disconnect()
        }
    }

    // MARK: - Filing

    private fun classify(articles: List<Article>, source: Source) {
        for (article in articles) {
            verdicts[article.id] = verdictFor(article, source)
        }
    }

    private fun verdictFor(article: Article, source: Source): TopicVerdict {
        val lexicon = when (source.topicMode) {
            TopicMode.FIXED -> TopicVerdict(source.fixedTopic, 1.0, emptyList(), isFallback = false)
            TopicMode.CLASSIFIED -> TopicClassifier.classify(
                article.displayTitle, article.summary, source.topicPrior, source.fixedTopic,
            )
        }
        val stored = modelDecisions[article.id] ?: return lexicon
        return applied(stored, lexicon, source)
    }

    /**
     * Folds a stored model decision onto the lexicon's verdict.
     *
     * "none" only hides a story where the source asked for that. Everywhere else
     * it leaves the placement alone: an outlet whose default is a fair guess would
     * rather be filed by guess than not appear.
     */
    private fun applied(decision: String, lexicon: TopicVerdict, source: Source): TopicVerdict {
        if (decision == "none") {
            if (!source.dropsUnsortable) return lexicon
            return TopicVerdict(null, 1.0, emptyList(), isFallback = false, decidedByModel = true)
        }
        val topic = Topic.from(decision) ?: return lexicon
        return TopicVerdict(topic, 1.0, emptyList(), isFallback = false, decidedByModel = true)
    }

    /**
     * Asks Claude where the stories from general outlets belong.
     *
     * Only articles with no stored decision are sent, so the steady state is a
     * handful per refresh. Every failure is silent and non-destructive: the
     * lexicon's verdicts stand, which is a complete working app, and the next
     * refresh tries again.
     */
    suspend fun fileWithModel(key: String) = withContext(Dispatchers.IO) {
        val pending = ArrayList<Triple<String, String, Source>>()
        for (source in sources.filter { it.topicMode == TopicMode.CLASSIFIED }) {
            for (article in articlesBySource[source.id].orEmpty()) {
                if (!modelDecisions.containsKey(article.id)) {
                    pending.add(Triple(article.id, article.displayTitle, source))
                }
            }
        }
        if (pending.isEmpty()) return@withContext

        for (batch in pending.chunked(ClaudeApi.CLASSIFY_BATCH)) {
            val body = ClaudeApi.requestBody(
                ClaudeApi.FILING_SYSTEM_PROMPT,
                ClaudeApi.filingPrompt(batch.map { it.second }),
                ClaudeApi.CLASSIFY_MAX_TOKENS,
            )
            val reply = runCatching { post(body, key) }.getOrNull() ?: break
            val text = ClaudeApi.extractText(reply) ?: break

            for ((number, decision) in ClaudeApi.parseDecisions(text)) {
                val entry = batch.getOrNull(number - 1) ?: continue
                val stored = when (decision) {
                    is ClaudeApi.Decision.Section -> decision.topic.id
                    ClaudeApi.Decision.Unplaced -> "none"
                }
                modelDecisions[entry.first] = stored
                verdicts[entry.first]?.let { existing ->
                    verdicts[entry.first] = applied(stored, existing, entry.third)
                }
            }
        }
        saveDecisions()
    }

    private fun post(body: String, key: String): String {
        val connection = URL(ClaudeApi.ENDPOINT).openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setRequestProperty("x-api-key", key)
        connection.setRequestProperty("anthropic-version", ClaudeApi.API_VERSION)
        connection.setRequestProperty("content-type", "application/json")
        connection.connectTimeout = 30_000
        connection.readTimeout = 60_000
        try {
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            if (connection.responseCode !in 200..299) {
                throw IllegalStateException("Anthropic HTTP ${connection.responseCode}")
            }
            return connection.inputStream.readBytes().toString(Charsets.UTF_8)
        } finally {
            connection.disconnect()
        }
    }

    // MARK: - Persistence
    //
    // A text file of "id decision" lines rather than JSON. There is no
    // serialisation dependency in this module, the data is two strings, and a
    // format you can read with your eyes is worth something when the question is
    // "why did that story go missing".

    private fun loadDecisions() {
        if (!decisionsFile.exists()) return
        runCatching {
            for (line in decisionsFile.readLines()) {
                val space = line.lastIndexOf(' ')
                if (space <= 0) continue
                modelDecisions[line.substring(0, space)] = line.substring(space + 1)
            }
        }
    }

    private fun saveDecisions() {
        // Pruned to the articles still held, so the file cannot grow without
        // bound as a wire churns through thousands of headlines.
        val live = articlesBySource.values.flatten().map { it.id }.toHashSet()
        modelDecisions.keys.retainAll(live)
        runCatching {
            decisionsFile.writeText(
                modelDecisions.entries.joinToString("\n") { "${it.key} ${it.value}" },
            )
        }
    }

    companion object {
        const val USER_AGENT =
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) " +
                "Chrome/120.0 Mobile Safari/537.36"
    }
}
