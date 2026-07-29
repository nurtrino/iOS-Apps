package com.nurtrino.polreader.ui

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.nurtrino.polreader.model.CatalogThread
import com.nurtrino.polreader.net.ChanApi
import com.nurtrino.polreader.net.ChanError
import kotlinx.coroutines.launch

/** Where a screen is in its load cycle. */
sealed interface LoadPhase {
    object Idle : LoadPhase
    object Loading : LoadPhase
    object Refreshing : LoadPhase
    object Loaded : LoadPhase

    /** Carries the one user-facing sentence decided in the network layer. */
    data class Failed(val message: String) : LoadPhase
}

/**
 * The /pol/ catalog.
 *
 * `catalog.json` returns the entire board in a single response, so there is no
 * pagination behind scrolling and no id list to hydrate in batches.
 *
 * Compose state (`mutableStateOf`) recomposes without any Flow plumbing, and is
 * mutated only from the main thread — `viewModelScope` dispatches there by
 * default, and the network call hops to IO internally.
 *
 * Note the setters are named `load`/`retry`, never `setThreads`: a function
 * named `setX` collides with the JVM setter generated for a property `x` and
 * fails the build with "platform declaration clash".
 */
class CatalogViewModel(application: Application) : AndroidViewModel(application) {

    var threads by mutableStateOf<List<CatalogThread>>(emptyList())
        private set

    var phase by mutableStateOf<LoadPhase>(LoadPhase.Idle)
        private set

    private val api = ChanApi.get(application)

    fun load(force: Boolean = false) {
        if (phase is LoadPhase.Loading || phase is LoadPhase.Refreshing) return
        phase = if (threads.isEmpty()) LoadPhase.Loading else LoadPhase.Refreshing

        viewModelScope.launch {
            try {
                threads = api.catalog(BOARD, force)
                phase = LoadPhase.Loaded
            } catch (error: ChanError) {
                phase = LoadPhase.Failed(error.message)
            } catch (error: Exception) {
                phase = LoadPhase.Failed("Something went wrong loading the catalog.")
            }
        }
    }

    fun loadIfNeeded() {
        if (threads.isEmpty() && phase is LoadPhase.Idle) load()
    }

    companion object {
        const val BOARD = "pol"
    }
}
