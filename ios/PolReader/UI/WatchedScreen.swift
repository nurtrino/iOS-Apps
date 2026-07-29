import SwiftUI

struct WatchedScreen: View {

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var navigator = Navigator()

    var body: some View {
        NavigationStack(path: $navigator.path) {
            Group {
                if library.watched.isEmpty {
                    EmptyState(
                        title: "Nothing watched",
                        message: "Swipe a thread in the catalog, or use the menu inside a thread, to keep it here.",
                        systemImage: "bookmark"
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Watched")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !library.watched.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button(role: .destructive) {
                                library.clearWatched()
                            } label: {
                                Label("Remove All", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .navigationDestination(for: ThreadRoute.self) { route in
                ThreadScreen(route: route)
            }
        }
        .environmentObject(navigator)
    }

    private var list: some View {
        List {
            ForEach(library.watched) { thread in
                NavigationLink(value: ThreadRoute(board: thread.board, no: thread.no)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(thread.title)
                            .font(.system(size: 14 * settings.textScale, weight: .medium))
                            .lineLimit(2)
                            .foregroundStyle(thread.isDead ? .secondary : .primary)

                        HStack(spacing: 8) {
                            Text("/\(thread.board)/")
                            if thread.isDead {
                                Label("Pruned", systemImage: "clock.badge.xmark")
                            } else if thread.unreadCount > 0 {
                                Text("+\(thread.unreadCount)")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Palette.accent)
                                    .foregroundStyle(.black)
                                    .clipShape(Capsule())
                            }
                            Text("\(thread.lastKnownReplyCount) replies")
                            Spacer(minLength: 0)
                            Text(RelativeTime.string(from: thread.savedAt))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        library.unwatch(board: thread.board, no: thread.no)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}
