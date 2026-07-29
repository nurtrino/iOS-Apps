package com.nurtrino.polreader.net

import android.content.Context
import com.nurtrino.polreader.model.CatalogThread
import com.nurtrino.polreader.model.Parsing
import com.nurtrino.polreader.model.Post
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.Cache
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException

/**
 * Every transport failure, collapsed into the small set of things a reader can
 * be told. The mapping happens here so no screen ever interprets an error.
 */
sealed class ChanError(override val message: String) : Exception(message) {
    // `override` is required: Throwable already declares `message`, and a
    // plain `val message` here is a hidden-member clash rather than a new
    // property. Narrowing String? to String is a valid covariant override and
    // is what lets callers use the text without a null check.
    object Offline : ChanError("No internet connection.")
    object TimedOut : ChanError("The request timed out.")

    /** On a thread request this is the ordinary end of a thread's life. */
    object NotFound : ChanError("This thread has been pruned or deleted.")

    object RateLimited : ChanError("Too many requests — waiting a moment before trying again.")
    class Server(code: Int) : ChanError("4chan returned an error ($code).")
    object Malformed : ChanError("Couldn't read the response from 4chan.")

    val isRetryable: Boolean get() = this !is NotFound
}

/**
 * Client for `a.4cdn.org`.
 *
 * 4chan's documentation asks for three things, and all three shape this class
 * more than anything else does:
 *
 *   - "Do not make more than one request per second."
 *   - "Thread updating should be set to a minimum of 10 seconds."
 *   - "Use If-Modified-Since when doing your requests."
 *
 * So this is not the usual bounded-concurrency batch fetcher. There is nothing
 * to fan out over — a whole thread arrives in one response — and the scarce
 * resource is request slots over time, not sockets.
 */
class ChanApi(cacheDir: File) {

    private val client = OkHttpClient.Builder()
        // Disk-backed cache: free offline-ish behaviour and a much faster relaunch.
        .cache(Cache(File(cacheDir, "chan-api"), 128L * 1024 * 1024))
        .build()

    private val paceMutex = Mutex()
    private var nextAllowedRequest = 0L

    /**
     * Last-Modified and the body it belongs to, per URL. Kept explicitly rather
     * than leaning on cache revalidation: 4chan sends no `Cache-Control`, so
     * heuristics would decide when to revalidate, and the documentation is
     * specific about wanting If-Modified-Since.
     */
    private val conditional = object : LinkedHashMap<String, ConditionalEntry>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ConditionalEntry>) =
            size > 24
    }

    private data class ConditionalEntry(val lastModified: String?, val body: String)

    suspend fun catalog(board: String, forceRefresh: Boolean = false): List<CatalogThread> =
        Parsing.catalogThreads(get("/$board/catalog.json", forceRefresh))

    /**
     * A complete thread in a single request. This endpoint is why there is no
     * partially-loaded thread state to model anywhere in this app.
     */
    suspend fun thread(board: String, no: Int, forceRefresh: Boolean = false): List<Post> =
        Parsing.threadPosts(get("/$board/thread/$no.json", forceRefresh))

    private suspend fun get(path: String, forceRefresh: Boolean): String =
        withContext(Dispatchers.IO) {
            val url = HOST + path
            pace()

            val builder = Request.Builder().url(url)
            val cached = synchronized(conditional) { conditional[url] }
            // A conditional request is not skipped on force-refresh:
            // revalidating is the cheap path, and a 304 there is a correct
            // answer meaning "nothing new", not a stale one.
            cached?.lastModified?.let { builder.header("If-Modified-Since", it) }

            val response = try {
                client.newCall(builder.build()).execute()
            } catch (e: java.net.SocketTimeoutException) {
                throw ChanError.TimedOut
            } catch (e: IOException) {
                throw ChanError.Offline
            }

            response.use {
                when (it.code) {
                    200 -> {
                        val body = it.body?.string() ?: throw ChanError.Malformed
                        synchronized(conditional) {
                            conditional[url] = ConditionalEntry(it.header("Last-Modified"), body)
                        }
                        body
                    }

                    304 -> cached?.body ?: throw ChanError.Malformed

                    404 -> {
                        // Threads 404 as a matter of course when they fall off
                        // the board. Drop any cached body so a stale copy
                        // cannot resurface.
                        synchronized(conditional) { conditional.remove(url) }
                        throw ChanError.NotFound
                    }

                    429 -> throw ChanError.RateLimited
                    else -> throw ChanError.Server(it.code)
                }
            }
        }

    /**
     * Reserve the next request slot, then wait for it.
     *
     * The reservation happens under the lock and before the delay, which is the
     * whole trick: concurrent callers each take a distinct slot instead of all
     * reading the same timestamp and firing simultaneously.
     */
    private suspend fun pace() {
        val delayMillis = paceMutex.withLock {
            val now = System.currentTimeMillis()
            val scheduled = maxOf(now, nextAllowedRequest)
            nextAllowedRequest = scheduled + MIN_REQUEST_INTERVAL_MS
            scheduled - now
        }
        if (delayMillis > 0) delay(delayMillis)
    }

    companion object {
        private const val HOST = "https://a.4cdn.org"
        private const val MIN_REQUEST_INTERVAL_MS = 1000L

        @Volatile
        private var instance: ChanApi? = null

        fun get(context: Context): ChanApi =
            instance ?: synchronized(this) {
                instance ?: ChanApi(context.applicationContext.cacheDir).also { instance = it }
            }
    }
}
