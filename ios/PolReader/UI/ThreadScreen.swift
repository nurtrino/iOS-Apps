import SwiftUI

struct ThreadScreen: View {

    let route: ThreadRoute

    @StateObject private var store: ThreadStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var filters: FilterStore
    @EnvironmentObject private var navigator: Navigator
    @Environment(\.openURL) private var systemOpenURL

    @State private var viewedAttachment: ViewedAttachment?
    @State private var externalLink: ExternalLink?
    /// Set by a tapped quotelink, consumed by the scroll reader below.
    @State private var scrollTarget: Int?

    init(route: ThreadRoute) {
        self.route = route
        _store = StateObject(wrappedValue: ThreadStore(board: route.board, threadNo: route.no))
    }

    var body: some View {
        content
            .navigationTitle(store.index == nil ? "Thread" : store.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            // Keyed on the route: without an id a `.task` never re-runs when a
            // different thread is swapped into the same position in the
            // hierarchy, and the screen stays blank forever while pull-to-
            // refresh mysteriously works.
            .task(id: route) {
                await store.loadIfNeeded()
                store.viewMode = settings.threadViewMode
                if settings.autoCollapseDepth > 0 {
                    store.applyAutoCollapse(depth: settings.autoCollapseDepth)
                }
                if settings.markThreadsRead {
                    library.markRead(board: route.board, no: route.no)
                }
                library.markSeen(board: route.board, no: route.no, replyCount: store.replyCount)
            }
            .onAppear { store.startAutoRefresh(interval: settings.refreshInterval) }
            .onDisappear { store.stopAutoRefresh() }
            .onChange(of: settings.refreshInterval) { interval in
                store.startAutoRefresh(interval: interval)
            }
            .onChange(of: settings.threadViewMode) { mode in
                store.viewMode = mode
            }
            .refreshable { await store.load(force: true) }
            .fullScreenCover(item: $viewedAttachment) { item in
                AttachmentViewer(board: route.board, attachment: item.attachment)
            }
            .sheet(item: $externalLink) { link in
                SafariSheet(url: link.url)
            }
            // Quotelinks are `polreader://` URLs inside the comment text; this
            // is where they turn back into navigation.
            .environment(\.openURL, OpenURLAction { url in
                handle(url)
            })
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            LoadingState(label: "Loading thread…")

        case .failed(let message):
            ErrorState(
                message: message,
                systemImage: store.isDead ? "clock.badge.xmark" : "exclamationmark.triangle",
                retry: store.isDead ? nil : { Task { await store.load(force: true) } }
            )

        case .idle, .refreshing, .loaded:
            if store.visibleNodes.isEmpty && store.index == nil {
                LoadingState(label: "Loading thread…")
            } else {
                postList
            }
        }
    }

    private var postList: some View {
        ScrollViewReader { proxy in
            List {
                if store.isDead {
                    Label("This thread has been pruned. You're reading a cached copy.",
                          systemImage: "clock.badge.xmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }

                ForEach(store.visibleNodes) { node in
                    if let post = store.post(node.postNo) {
                        PostRow(
                            board: route.board,
                            post: post,
                            node: node,
                            isCollapsed: store.isCollapsed(node.postNo),
                            descendantCount: store.descendantCounts[node.postNo] ?? 0,
                            backlinks: store.replies(to: node.postNo),
                            isNew: store.newPostNumbers.contains(node.postNo),
                            ancestors: store.ancestors(of: node.postNo),
                            onToggleCollapse: { store.toggleCollapse(node.postNo) },
                            onSelectPost: { scroll(to: $0, using: proxy) },
                            onOpenAttachment: {
                                if let attachment = post.attachment {
                                    open(attachment: attachment)
                                }
                            }
                        )
                        .id(node.postNo)
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                        .listRowSeparator(.hidden)
                        // Secondary actions are swipes, not buttons: a button
                        // nested in a row that also navigates swallows taps
                        // meant for the row.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                copyPostLink(post.no)
                            } label: {
                                Label("Copy Link", systemImage: "link")
                            }
                            .tint(.gray)
                        }
                    }
                }

                if store.hiddenByFiltersCount > 0 {
                    Text("\(store.hiddenByFiltersCount) post\(store.hiddenByFiltersCount == 1 ? "" : "s") hidden by filters")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .task(id: route.focusPost) {
                guard let focus = route.focusPost else { return }
                scroll(to: focus, using: proxy)
            }
            .onChange(of: scrollTarget) { target in
                guard let target else { return }
                scroll(to: target, using: proxy)
                scrollTarget = nil
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    library.toggleWatch(board: route.board, no: route.no,
                                        title: store.title, replyCount: store.replyCount)
                } label: {
                    Label(
                        library.isWatching(board: route.board, no: route.no) ? "Unwatch" : "Watch",
                        systemImage: library.isWatching(board: route.board, no: route.no) ? "bookmark.fill" : "bookmark"
                    )
                }

                Picker("View", selection: Binding(
                    get: { store.viewMode },
                    set: { store.viewMode = $0 }
                )) {
                    ForEach(ThreadViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if store.viewMode == .threaded {
                    Button("Collapse All") { store.collapseAll() }
                    Button("Expand All") { store.expandAll() }
                }

                Divider()

                Button {
                    Task { await store.load(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                if let url = MediaURL.webThread(board: route.board, threadNo: route.no) {
                    Button {
                        openExternally(url)
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }

        ToolbarItem(placement: .status) {
            if let posters = store.posterCount {
                Text("\(store.replyCount) replies · \(posters) posters")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(store.replyCount) replies")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func handle(_ url: URL) -> OpenURLAction.Result {
        guard let action = CommentLink.parse(url) else {
            openExternally(url)
            return .handled
        }
        switch action {
        case .post(let no):
            // Same thread: the reader stays put and the list moves.
            if store.index?.contains(no) == true {
                scrollTarget = no
            }
            return .handled

        case .thread(let board, let thread, let post):
            navigator.open(ThreadRoute(board: board, no: thread, focusPost: post))
            return .handled

        case .board(let board):
            if let url = MediaURL.webBoard(board) {
                openExternally(url)
            }
            return .handled
        }
    }

    private func scroll(to postNo: Int, using proxy: ScrollViewProxy) {
        guard store.index?.contains(postNo) == true else { return }
        // Expanding first: scrolling to a post inside a collapsed subtree would
        // otherwise silently do nothing.
        withAnimation {
            proxy.scrollTo(postNo, anchor: .top)
        }
    }

    private func open(attachment: Attachment) {
        // Every attachment expands in the same viewer now, video included. The
        // viewer picks a playback backend and, on the one combination nothing
        // can decode (WebM below iOS 17.4), offers the browser itself.
        viewedAttachment = ViewedAttachment(attachment: attachment)
    }

    private func openExternally(_ url: URL) {
        if settings.useInAppBrowser, url.scheme?.hasPrefix("http") == true {
            externalLink = ExternalLink(url: url)
        } else {
            systemOpenURL(url)
        }
    }

    private func copyPostLink(_ no: Int) {
        guard let url = MediaURL.webThread(board: route.board, threadNo: route.no, postNo: no) else { return }
        UIPasteboard.general.string = url.absoluteString
    }
}

/// Wrapper so an `Attachment` can drive `fullScreenCover(item:)`.
struct ViewedAttachment: Identifiable {
    let attachment: Attachment
    var id: Int { attachment.tim }
}

/// Wrapper so a URL can drive `sheet(item:)`.
///
/// Deliberately not a retroactive `URL: Identifiable` conformance — that would
/// collide the moment the SDK declares one of its own.
struct ExternalLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
