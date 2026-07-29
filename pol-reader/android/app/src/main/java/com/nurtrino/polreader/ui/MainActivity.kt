package com.nurtrino.polreader.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.nurtrino.polreader.model.CatalogThread
import com.nurtrino.polreader.text.CommentBlock
import com.nurtrino.polreader.text.CommentParserCache
import com.nurtrino.polreader.text.CommentStyle

/**
 * Android entry point.
 *
 * The Compose UI here is deliberately a thin slice — a catalog list — that
 * exercises the whole shared stack end to end: network, lenient model parsing,
 * the comment parser, and the styled-text mapping. The full screen set is the
 * follow-up; what this proves is that the ported logic compiles, links and
 * renders.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            PolReaderTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    CatalogScreen()
                }
            }
        }
    }
}

// Sampled from the icon artwork rather than assumed from a brand hex.
private val Accent = Color(0xFF8CB33F)
private val Greentext = Color(0xFF8DB33A)
private val Quotelink = Color(0xFF5F89AC)
private val Deadlink = Color(0xFFCC4040)

@Composable
fun PolReaderTheme(content: @Composable () -> Unit) {
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    MaterialTheme(
        colorScheme = if (isDark) {
            darkColorScheme(primary = Accent, background = Color(0xFF12161A))
        } else {
            lightColorScheme(primary = Accent)
        },
        content = content,
    )
}

@Composable
fun CatalogScreen(model: CatalogViewModel = viewModel()) {
    // LaunchedEffect is keyed by construction, so it does not have SwiftUI's
    // stale-task trap: a new key means a new effect.
    LaunchedEffect(Unit) { model.loadIfNeeded() }

    when (val phase = model.phase) {
        is LoadPhase.Loading -> Centered { CircularProgressIndicator() }

        is LoadPhase.Failed -> Centered {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(phase.message, style = MaterialTheme.typography.bodyMedium)
                Button(onClick = { model.load(force = true) }, modifier = Modifier.padding(top = 12.dp)) {
                    Text("Try Again")
                }
            }
        }

        else -> {
            if (model.threads.isEmpty()) {
                Centered { Text("No threads.") }
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(model.threads, key = { it.op.no }) { thread ->
                        CatalogRow(thread)
                    }
                }
            }
        }
    }
}

@Composable
private fun Centered(content: @Composable () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
        content = { content() },
    )
}

@Composable
private fun CatalogRow(thread: CatalogThread) {
    Column(modifier = Modifier.fillMaxWidth()) {
        thread.op.subject?.let { subject ->
            Text(
                text = subject,
                color = Accent,
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }

        CommentText(
            blocks = CommentParserCache.blocks(thread.op.comment),
            maxLines = 6,
        )

        Row(
            modifier = Modifier.padding(top = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("${thread.replyCount} replies", fontSize = 11.sp)
            Text("${thread.imageCount} images", fontSize = 11.sp)
            thread.op.posterId?.let { Text("ID $it", fontSize = 11.sp) }
        }
    }
}

/** Maps parsed blocks onto Compose styled text. */
@Composable
private fun CommentText(blocks: List<CommentBlock>, maxLines: Int = Int.MAX_VALUE) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        for (block in blocks) {
            when (block) {
                is CommentBlock.Paragraph -> Text(
                    text = buildAnnotatedString {
                        append(block.text)
                        for (span in block.spans) {
                            if (span.start < 0 || span.end > block.text.length) continue
                            val style = when (span.style) {
                                CommentStyle.Italic -> SpanStyle(fontStyle = FontStyle.Italic)
                                CommentStyle.Bold -> SpanStyle(fontWeight = FontWeight.Bold)
                                CommentStyle.Underline ->
                                    SpanStyle(textDecoration = TextDecoration.Underline)
                                // Same colour as the background: present and
                                // selectable, unreadable until revealed.
                                CommentStyle.Spoiler ->
                                    SpanStyle(color = Color.Transparent, background = Color.Gray)
                                CommentStyle.Greentext -> SpanStyle(color = Greentext)
                                CommentStyle.Deadlink -> SpanStyle(
                                    color = Deadlink,
                                    textDecoration = TextDecoration.LineThrough,
                                )
                                CommentStyle.InlineCode, CommentStyle.ShiftJis ->
                                    SpanStyle(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                                is CommentStyle.Link, is CommentStyle.Quotelink,
                                is CommentStyle.BoardLink -> SpanStyle(
                                    color = Quotelink,
                                    textDecoration = TextDecoration.Underline,
                                )
                            }
                            addStyle(style, span.start, span.end)
                        }
                    },
                    fontSize = 13.sp,
                    maxLines = maxLines,
                    overflow = TextOverflow.Ellipsis,
                )

                // Its own scroller — the reason the parser emits blocks rather
                // than one styled string.
                is CommentBlock.Code -> Text(
                    text = block.text,
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                    fontSize = 12.sp,
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color.Gray.copy(alpha = 0.15f))
                        .padding(8.dp),
                )
            }
        }
    }
}
