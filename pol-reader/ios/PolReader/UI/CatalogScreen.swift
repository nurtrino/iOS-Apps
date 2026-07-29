import SwiftUI

struct CatalogScreen: View {

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var navigator = Navigator()

    var body: some View {
        NavigationStack(path: $navigator.path) {
            content
                .navigationTitle("/pol/")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $catalog.searchText, prompt: "Search subjects and posts")
                .toolbar { toolbar }
                .refreshable { await catalog.load(force: true) }
                .task { await catalog.loadIfNeeded() }
                .navigationDestination(for: ThreadRoute.self) { route in
                    ThreadScreen(route: route)
                }
        }
        .environmentObject(navigator)
        .sheet(isPresented: Binding(
            get: { !settings.hasSeenContentNotice },
            set: { if !$0 { settings.hasSeenContentNotice = true } }
        )) {
            ContentNoticeSheet()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch catalog.phase {
        case .loading:
            LoadingState(label: "Loading catalog…")

        case .failed(let message):
            ErrorState(message: message) {
                Task { await catalog.load(force: true) }
            }

        case .idle, .refreshing, .loaded:
            if catalog.allThreads.isEmpty {
                EmptyState(title: "No threads", message: "Pull down to refresh.")
            } else if catalog.matchingThreads.isEmpty {
                EmptyState(
                    title: "Nothing matches",
                    message: catalog.hiddenByFiltersCount > 0
                        ? "\(catalog.hiddenByFiltersCount) threads are hidden by your filters."
                        : "Try a different search.",
                    systemImage: "magnifyingglass"
                )
            } else {
                threadList
            }
        }
    }

    @ViewBuilder
    private var threadList: some View {
        switch settings.catalogLayout {
        case .grid:
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 172), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(catalog.displayedThreads) { thread in
                        NavigationLink(value: ThreadRoute(board: catalog.board, no: thread.op.no)) {
                            CatalogGridCell(board: catalog.board, thread: thread)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                showMoreFooter
            }

        case .list:
            List {
                ForEach(catalog.displayedThreads) { thread in
                    NavigationLink(value: ThreadRoute(board: catalog.board, no: thread.op.no)) {
                        CatalogListRow(board: catalog.board, thread: thread)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        watchButton(for: thread)
                    }
                }
                showMoreFooter
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var showMoreFooter: some View {
        if catalog.hasMoreToShow {
            // The whole board arrived in one response; this paginates purely to
            // bound how many rows SwiftUI builds at once.
            Button("Show More") { catalog.showMore() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else if catalog.hiddenByFiltersCount > 0 {
            Text("\(catalog.hiddenByFiltersCount) thread\(catalog.hiddenByFiltersCount == 1 ? "" : "s") hidden by filters")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    private func watchButton(for thread: CatalogThread) -> some View {
        Button {
            library.toggleWatch(
                board: catalog.board,
                no: thread.op.no,
                title: thread.op.subject ?? "Thread \(thread.op.no)",
                replyCount: thread.replyCount
            )
        } label: {
            Label(
                library.isWatching(board: catalog.board, no: thread.op.no) ? "Unwatch" : "Watch",
                systemImage: "bookmark"
            )
        }
        .tint(Palette.accent)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Picker("Sort", selection: $catalog.sort) {
                    ForEach(CatalogSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                Picker("Layout", selection: $settings.catalogLayout) {
                    ForEach(CatalogLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                Divider()
                Button {
                    Task { await catalog.load(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }

        ToolbarItem(placement: .status) {
            if let updated = catalog.lastUpdated {
                Text("Updated \(RelativeTime.string(from: updated))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Cells

struct CatalogGridCell: View {
    let board: String
    let thread: CatalogThread

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let attachment = thread.op.attachment {
                // Aspect-correct and generous: the OP image is what a
                // reader is actually scanning the catalog for. Still the CDN
                // thumbnail, though — a screen of full-size files is megabytes.
                PostThumbnail(board: board, attachment: attachment,
                              mode: settings.thumbnailMode,
                              revealSpoilers: settings.revealSpoilersAutomatically,
                              layout: .fill(maxHeight: 230),
                              allowsReveal: false)
            }

            HStack(spacing: 4) {
                ThreadBadges(post: thread.op)
                Spacer(minLength: 0)
                Text("\(thread.replyCount)")
                    .font(.caption2.weight(.semibold))
                Image(systemName: "bubble.left")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.secondary)

            if let subject = thread.op.subject {
                Text(subject)
                    .font(.system(size: 13 * settings.textScale, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .lineLimit(2)
            }

            Text(previewText)
                .font(.system(size: 12 * settings.textScale))
                .foregroundStyle(library.isRead(board: board, no: thread.op.no) ? .secondary : .primary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var previewText: String {
        CommentParserCache.shared.blocks(for: thread.op.comment)
            .compactMap { block -> String? in
                if case .paragraph(let paragraph) = block { return paragraph.text }
                return nil
            }
            .joined(separator: " ")
    }
}

struct CatalogListRow: View {
    let board: String
    let thread: CatalogThread

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let attachment = thread.op.attachment {
                PostThumbnail(board: board, attachment: attachment,
                              mode: settings.thumbnailMode,
                              revealSpoilers: settings.revealSpoilersAutomatically,
                              layout: .square(76),
                              allowsReveal: false)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let subject = thread.op.subject {
                    Text(subject)
                        .font(.system(size: 14 * settings.textScale, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .lineLimit(1)
                }

                Text(previewText)
                    .font(.system(size: 12 * settings.textScale))
                    .foregroundStyle(library.isRead(board: board, no: thread.op.no) ? .secondary : .primary)
                    .lineLimit(3)

                HStack(spacing: 8) {
                    ThreadBadges(post: thread.op)
                    Label("\(thread.replyCount)", systemImage: "bubble.left")
                    Label("\(thread.imageCount)", systemImage: "photo")
                    if let modified = thread.lastModified {
                        Text(RelativeTime.string(from: modified))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var previewText: String {
        CommentParserCache.shared.blocks(for: thread.op.comment)
            .compactMap { block -> String? in
                if case .paragraph(let paragraph) = block { return paragraph.text }
                return nil
            }
            .joined(separator: " ")
    }
}

/// Sticky / closed / archived / limit markers.
struct ThreadBadges: View {
    let post: Post

    var body: some View {
        HStack(spacing: 4) {
            if post.isSticky {
                Image(systemName: "pin.fill").foregroundStyle(.orange)
            }
            if post.isClosed {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            }
            if post.isArchived {
                Image(systemName: "archivebox.fill").foregroundStyle(.secondary)
            }
            if post.hitBumpLimit {
                Image(systemName: "arrow.down.to.line").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 9))
    }
}
