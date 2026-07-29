import SwiftUI

/// The reading queue.
///
/// Saved articles keep their own copy of the text rather than a reference into
/// the feed. Feeds roll off — most of these carry twenty or forty items and
/// drop the rest — so a saved article that was only a pointer would turn into a
/// dead row within a day.
struct SavedScreen: View {

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var read: ReadStore
    @EnvironmentObject private var settings: SettingsStore

    @State private var webLink: WebLink?
    @State private var confirmingClear = false

    var body: some View {
        Group {
            if read.saved.isEmpty {
                StateView(
                    systemImage: "bookmark",
                    title: "Nothing saved",
                    message: "Swipe a headline, or use the bookmark button while reading."
                )
            } else {
                list
            }
        }
        .navigationTitle("Saved")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !read.saved.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .navigationDestination(for: Article.self) { ArticleScreen(article: $0) }
        .confirmationDialog("Remove all saved articles?",
                            isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button("Remove \(read.saved.count)", role: .destructive) { read.clearSaved() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $webLink) { link in
            SafariSheet(url: link.url).ignoresSafeArea()
        }
    }

    private var list: some View {
        List {
            ForEach(read.saved) { article in
                NavigationLink(value: article) {
                    ArticleRow(article: article,
                               sourceName: catalog.source(id: article.sourceID)?.name ?? "Saved",
                               style: catalog.source(id: article.sourceID)?.style ?? .article,
                               isRead: read.isRead(article))
                }
                .articleActions(article) { webLink = WebLink(url: $0) }
            }
            .onDelete { read.removeSaved(at: $0) }
        }
        .listStyle(.plain)
    }
}
