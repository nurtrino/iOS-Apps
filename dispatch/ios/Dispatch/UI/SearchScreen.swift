import SwiftUI

/// Search across everything currently loaded.
///
/// Local only, and it says so. None of these sources offers a search API worth
/// using — ZeroHedge's is a site page, Telegram's needs an account, Steam's does
/// not exist — so a remote search would mean scraping four different result
/// pages to produce something worse than filtering what is already on the
/// device. Filtering the loaded feeds is instant and honest about its scope.
struct SearchScreen: View {

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore

    @State private var query = ""
    @State private var sourceFilter: String?
    @State private var webLink: WebLink?

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    StateView(
                        systemImage: "magnifyingglass",
                        title: "Search your feeds",
                        message: "Looks through every story loaded on this device — "
                            + "\(feed.everyArticle.count) right now."
                    )
                } else if results.isEmpty {
                    StateView(
                        systemImage: "questionmark.circle",
                        title: "No matches",
                        message: "Nothing loaded matches “\(query)”. Pull the feed down to fetch more."
                    )
                } else {
                    list
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Headlines and text")
            .navigationTitle("Search")
            .toolbar { filterMenu }
            .navigationDestination(for: Article.self) { ArticleScreen(article: $0) }
        }
        .sheet(item: $webLink) { link in
            SafariSheet(url: link.url).ignoresSafeArea()
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(results) { article in
                    NavigationLink(value: article) {
                        ArticleRow(article: article,
                                   sourceName: catalog.source(id: article.sourceID)?.name ?? "",
                                   style: .wire,
                                   isRead: read.isRead(article))
                    }
                    .articleActions(article) { webLink = WebLink(url: $0) }
                }
            } header: {
                Text("\(results.count) result\(results.count == 1 ? "" : "s")")
            }
        }
        .listStyle(.plain)
    }

    @ToolbarContentBuilder
    private var filterMenu: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    sourceFilter = nil
                } label: {
                    Label("All sources",
                          systemImage: sourceFilter == nil ? "checkmark" : "tray.full")
                }
                Divider()
                ForEach(catalog.enabledSources) { source in
                    Button {
                        sourceFilter = source.id
                    } label: {
                        Label(source.name,
                              systemImage: sourceFilter == source.id ? "checkmark" : source.kind.systemImage)
                    }
                }
            } label: {
                Image(systemName: sourceFilter == nil
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
        }
    }

    private var results: [Article] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        // Every word has to appear somewhere in the item, in any order. Plain
        // substring matching on the whole phrase misses "ukraine drone" on a
        // headline reading "drone strike in Ukraine", which is the query
        // someone actually typed.
        let terms = needle.split(separator: " ").map(String.init)

        var seen = Set<String>()
        var matches: [Article] = []

        for article in feed.everyArticle {
            if let sourceFilter, article.sourceID != sourceFilter { continue }
            guard seen.insert(article.id).inserted else { continue }

            let haystack = (article.displayTitle + " " + article.summary + " "
                            + (article.context ?? "")).lowercased()
            guard terms.allSatisfy({ haystack.contains($0) }) else { continue }
            matches.append(article)
        }
        return matches.sorted { $0.sortDate > $1.sortDate }
    }
}
