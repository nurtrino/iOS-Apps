package com.nurtrino.dispatch

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountBalance
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.SportsEsports
import androidx.compose.material.icons.filled.TrendingUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Divider
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.nurtrino.dispatch.core.Article
import com.nurtrino.dispatch.core.DateParsing
import com.nurtrino.dispatch.core.Topic
import kotlinx.coroutines.launch

/**
 * The Android port of Dispatch.
 *
 * Four sections, each its own place, the same as iOS: a story is filed into
 * exactly one by the shared classifier in `core`. What is here is the reading
 * app — fetch, file, list, open. The live rail, the Steam library, the release
 * calendar and the written brief are iOS-only so far; the README says which.
 */
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { DispatchApp() }
    }
}

/** Per-topic colour, so each part of the app feels like a different place. */
object TopicTheme {
    fun accent(topic: Topic): Color = when (topic) {
        Topic.WAR -> Color(0xFFD84537)
        Topic.POLITICS -> Color(0xFF5C8AD4)
        Topic.ECONOMICS -> Color(0xFF3EB47A)
        Topic.GAMING -> Color(0xFF7E71E0)
    }

    fun icon(topic: Topic): ImageVector = when (topic) {
        Topic.WAR -> Icons.Filled.Shield
        Topic.POLITICS -> Icons.Filled.AccountBalance
        Topic.ECONOMICS -> Icons.Filled.TrendingUp
        Topic.GAMING -> Icons.Filled.SportsEsports
    }
}

private val Ground = Color(0xFF1B1C22)
private val Surface = Color(0xFF24252C)
private val Tint = Color(0xFFE6E8EC)

class FeedViewModel(private val repository: FeedRepository) : ViewModel() {

    var isLoading by mutableStateOf(false)
        private set

    /** Bumped when the articles change, to make Compose re-read the repository. */
    var revision by mutableStateOf(0)
        private set

    init {
        repository.hydrate()
        revision++
        refresh()
    }

    fun articles(topic: Topic): List<Article> = repository.articles(topic)

    fun sourceName(id: String) = repository.sourceName(id)

    fun refresh() {
        if (isLoading) return
        isLoading = true
        viewModelScope.launch {
            repository.refresh()
            revision++
            isLoading = false
        }
    }

    class Factory(private val repository: FeedRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            FeedViewModel(repository) as T
    }
}

@Composable
fun DispatchApp() {
    val context = LocalContext.current
    val repository = remember { FeedRepository(context.applicationContext) }
    val model: FeedViewModel = viewModel(factory = FeedViewModel.Factory(repository))
    var topic by remember { mutableStateOf(Topic.WAR) }

    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Tint,
            background = Ground,
            surface = Ground,
        ),
    ) {
        Scaffold(
            containerColor = Ground,
            topBar = { TopicBar(topic, model) },
            bottomBar = { SectionBar(topic) { topic = it } },
        ) { padding ->
            Box(Modifier.padding(padding)) {
                ArticleList(topic, model)
            }
        }
    }
}

// Material3's top app bar is still behind an opt-in. Annotated here rather than
// suppressed project-wide, so the next experimental API someone reaches for is a
// decision rather than a silence.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TopicBar(topic: Topic, model: FeedViewModel) {
    TopAppBar(
        title = {
            Text(
                topic.title,
                fontWeight = FontWeight.Bold,
                color = TopicTheme.accent(topic),
            )
        },
        actions = {
            if (model.isLoading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp).padding(end = 4.dp),
                    strokeWidth = 2.dp,
                    color = TopicTheme.accent(topic),
                )
            } else {
                IconButton(onClick = { model.refresh() }) {
                    Icon(Icons.Filled.Refresh, "Refresh", tint = Tint)
                }
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Ground),
    )
}

@Composable
private fun SectionBar(selected: Topic, onSelect: (Topic) -> Unit) {
    NavigationBar(containerColor = Surface) {
        for (topic in Topic.entries) {
            NavigationBarItem(
                selected = topic == selected,
                onClick = { onSelect(topic) },
                icon = { Icon(TopicTheme.icon(topic), topic.title) },
                label = { Text(topic.title, fontSize = 11.sp) },
                colors = NavigationBarItemDefaults.colors(
                    selectedIconColor = TopicTheme.accent(topic),
                    selectedTextColor = TopicTheme.accent(topic),
                    indicatorColor = Ground,
                    unselectedIconColor = Color(0xFF8A8A93),
                    unselectedTextColor = Color(0xFF8A8A93),
                ),
            )
        }
    }
}

@Composable
private fun ArticleList(topic: Topic, model: FeedViewModel) {
    val context = LocalContext.current
    // Reading `revision` here is what subscribes this list to the repository's
    // changes: the articles live outside Compose's snapshot system, so without it
    // a refresh would land and nothing would redraw.
    @Suppress("UNUSED_EXPRESSION") model.revision
    val articles = model.articles(topic)

    if (articles.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                if (model.isLoading) "Loading ${topic.title}…" else "Nothing sorted here yet",
                color = Color(0xFF8A8A93),
            )
        }
        return
    }

    LazyColumn(Modifier.fillMaxSize()) {
        items(articles, key = { it.id }) { article ->
            ArticleRow(
                article = article,
                sourceName = model.sourceName(article.sourceId),
                accent = TopicTheme.accent(topic),
                onOpen = {
                    article.link?.let {
                        runCatching {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(it)))
                        }
                    }
                },
            )
            Divider(color = Color(0xFF2E2F37), thickness = 0.5.dp)
        }
    }
}

@Composable
private fun ArticleRow(
    article: Article,
    sourceName: String,
    accent: Color,
    onOpen: () -> Unit,
) {
    Surface(color = Ground) {
        Column(
            Modifier
                .fillMaxWidth()
                .clickable(onClick = onOpen)
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(5.dp).background(accent, CircleShape))
                Spacer(Modifier.size(6.dp))
                Text(
                    sourceName.uppercase(),
                    color = accent,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                )
                article.published?.let {
                    Text(
                        "  ·  " + DateParsing.age(it),
                        color = Color(0xFF7A7A85),
                        fontSize = 10.sp,
                    )
                }
            }

            Spacer(Modifier.height(4.dp))

            Text(
                article.displayTitle,
                color = Color(0xFFECECF1),
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )

            if (article.summary.isNotEmpty() && article.summary != article.displayTitle) {
                Spacer(Modifier.height(3.dp))
                Text(
                    article.summary,
                    color = Color(0xFF9A9AA4),
                    fontSize = 13.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}


