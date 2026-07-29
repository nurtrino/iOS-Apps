import SwiftUI

/// The catch-up block at the top of a topic.
///
/// This is a **digest, not a summary**, and the difference is worth being
/// straight about. Writing prose that says what happened needs a language
/// model, which would mean either tens of megabytes on device or sending every
/// headline you read to somebody's API. Neither is worth it for a line of text.
///
/// What it does instead is answer "what just happened" with material that is
/// already true: the newest few headlines, one line each, numbered, plus a
/// state line built from real numbers where the topic has any. On Markets that
/// is the actual index moves and whether a release has already landed today —
/// which is the specific question that section gets asked at nine in the
/// morning.
///
/// Selection is recency first, then one item per source before any source gets
/// a second. A brief made of five posts from the same wire is not a brief.
struct BriefSection: View {

    let topic: Topic
    var onOpen: (Article) -> Void

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var markets: MarketStore
    @EnvironmentObject private var live: LiveStore

    /// How far back the brief looks. Long enough to have something overnight,
    /// short enough that "just happened" is not a lie.
    private static let window: TimeInterval = 12 * 3600

    private var candidates: [Article] {
        let sources = catalog.sources(reaching: topic)
        let cutoff = Date().addingTimeInterval(-BriefSection.window)
        return feed.articles(for: topic, from: sources)
            .filter { $0.sortDate > cutoff }
    }

    /// Newest first, one per source, then fill from what is left.
    private var items: [Article] {
        let pool = candidates
        var seenSources = Set<String>()
        var picked: [Article] = []

        for article in pool where !seenSources.contains(article.sourceID) {
            seenSources.insert(article.sourceID)
            picked.append(article)
            if picked.count == 5 { break }
        }
        if picked.count < 5 {
            let pickedIDs = Set(picked.map(\.id))
            picked += pool.filter { !pickedIDs.contains($0.id) }.prefix(5 - picked.count)
        }
        return picked.sorted { $0.sortDate > $1.sortDate }
    }

    var body: some View {
        if settings.showBrief, !items.isEmpty {
            Section {
                if let state = stateLine {
                    Text(state)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TopicTheme.accent(topic))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowSeparator(.hidden)
                }

                ForEach(Array(items.enumerated()), id: \.element.id) { index, article in
                    Button {
                        onOpen(article)
                    } label: {
                        BriefRow(index: index + 1,
                                 article: article,
                                 sourceName: catalog.source(id: article.sourceID)?.name ?? "",
                                 isRead: read.isRead(article),
                                 accent: TopicTheme.accent(topic))
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 11, weight: .bold))
                    Text("BRIEF")
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(0.8)
                    Spacer()
                    Text("last 12 hours")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
                .foregroundStyle(TopicTheme.accent(topic))
                .textCase(nil)
            }
        }
    }

    /// The one line of real fact a topic can offer, where it has one.
    private var stateLine: String? {
        switch topic {
        case .economics:
            var parts: [String] = []
            for series in markets.series {
                parts.append("\(series.symbol) \(series.formattedChange)")
            }
            if let release = todaysRelease {
                parts.append(release)
            }
            return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")

        case .war:
            let count = live.liveNow.count
            guard count > 0 else { return nil }
            return "\(count) stream\(count == 1 ? "" : "s") live now"

        case .politics, .gaming:
            return nil
        }
    }

    /// A release that has already happened today, which is the thing worth
    /// saying — "CPI landed at 8:30" beats any headline about it.
    private var todaysRelease: String? {
        let today = EconCalendar.upcoming(limit: 6).filter(\.isToday)
        guard let event = today.last(where: \.isPast) ?? today.first else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let time = formatter.string(from: event.date)

        return event.isPast ? "\(event.title) released \(time)" : "\(event.title) at \(time)"
    }
}

private struct BriefRow: View {

    let index: Int
    let article: Article
    let sourceName: String
    let isRead: Bool
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(index)")
                .font(.system(size: 11, weight: .heavy).monospacedDigit())
                .foregroundStyle(accent)
                .frame(width: 14, alignment: .trailing)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(article.displayTitle)
                    .font(.system(size: 14, weight: isRead ? .regular : .medium))
                    .foregroundStyle(isRead ? .secondary : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Text(sourceName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    if let age = article.published?.feedAge {
                        Text("·").foregroundStyle(.tertiary)
                        Text(age)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
