import SwiftUI

struct NewsScreen: View {

    @EnvironmentObject private var news: NewsStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var articleState: ArticleStateStore

    /// nil means all sources.
    @State private var sourceFilter: String?
    @State private var showSavedOnly = false
    @State private var search = ""
    @State private var presented: Article?

    var body: some View {
        content
            .navigationTitle(showSavedOnly ? "Saved" : "News")
            .toolbar { toolbarContent }
            .searchable(text: $search, prompt: "Search headlines")
            .refreshable { await news.refresh(enabled: settings.enabledSources) }
            .task { await news.refreshIfStale(enabled: settings.enabledSources) }
            .sheet(item: $presented) { article in
                if let url = article.link {
                    SafariSheet(url: url).ignoresSafeArea()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch news.phase {
        case .idle, .loading:
            LoadingView(label: "Pulling the wires…")
        case .failed(let message):
            ErrorView(message: message) {
                Task { await news.refresh(enabled: settings.enabledSources) }
            }
        case .loaded:
            if filtered.isEmpty {
                EmptyStateView(
                    systemImage: showSavedOnly ? "bookmark" : "newspaper",
                    title: showSavedOnly ? "Nothing saved" : "Nothing here",
                    message: showSavedOnly
                        ? "Swipe a story right to save it for later."
                        : "No stories match. Try clearing the filter or search.")
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            if !news.failures.isEmpty && !showSavedOnly {
                Section {
                    // An advisory, not an error: the feed below is still real.
                    Text(advisory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(filtered) { article in
                    ArticleRow(
                        article: article,
                        isRead: articleState.isRead(article),
                        isSaved: articleState.isSaved(article)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        articleState.markRead(article)
                        if article.link != nil { presented = article }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            articleState.toggleSaved(article)
                        } label: {
                            Label(articleState.isSaved(article) ? "Unsave" : "Save",
                                  systemImage: articleState.isSaved(article) ? "bookmark.slash" : "bookmark")
                        }
                        .tint(Color.accentColor)
                    }
                    .contextMenu {
                        if let url = article.link {
                            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                        }
                        Button {
                            articleState.toggleSaved(article)
                        } label: {
                            Label(articleState.isSaved(article) ? "Remove from Saved" : "Save",
                                  systemImage: "bookmark")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var advisory: String {
        let names = news.failures.keys.sorted().joined(separator: ", ")
        return "Quiet right now: \(names)"
    }

    private var filtered: [Article] {
        var articles = showSavedOnly ? articleState.saved : news.articles
        if let sourceFilter {
            articles = articles.filter { $0.sourceID == sourceFilter }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            articles = articles.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.summary.localizedCaseInsensitiveContains(query)
            }
        }
        return articles
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                showSavedOnly.toggle()
            } label: {
                Image(systemName: showSavedOnly ? "bookmark.fill" : "bookmark")
            }
            .accessibilityLabel(showSavedOnly ? "Show all stories" : "Show saved stories")
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Picker("Source", selection: $sourceFilter) {
                    Text("All Sources").tag(String?.none)
                    ForEach(FeedCatalog.sources.filter { settings.isEnabled($0) }) { source in
                        Text(source.name).tag(String?.some(source.id))
                    }
                }
            } label: {
                Image(systemName: sourceFilter == nil
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
        }
    }
}
