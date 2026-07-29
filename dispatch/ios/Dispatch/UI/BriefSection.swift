import SwiftUI

/// The catch-up block at the top of a topic.
///
/// Two layers, and they degrade independently. The base is a **digest** built
/// from material that is already true: the newest few headlines, one line
/// each, numbered, plus a state line built from real numbers where the topic
/// has any. On Markets that is the actual index moves and whether a release
/// has already landed today — the specific question that section gets asked at
/// nine in the morning.
///
/// On top of it, when an Anthropic key is saved and the toggle is on, sits a
/// **written summary**: a few bullets from the Claude API saying what just
/// happened (see `SummaryStore` for what is sent and how rarely). No key, no
/// network, or a failed request — the digest stands alone, same as before.
///
/// The two layers read from the same pool but select differently, which is
/// deliberate:
///
/// **The rows are strictly one per source.** Filling spare slots with a
/// second and third post from whichever wire is loudest is how the War brief
/// turned into three consecutive Warfront Witness posts from one thread —
/// three rows saying one thing, directly above the block that already shows
/// that channel in full. Four distinct sources beats five rows.
///
/// **The summary sees more, including the sources shown elsewhere.** A
/// frontline wire is the best material there is for "what just happened", so it
/// still feeds the prose even where it is excluded from the rows — capped per
/// source so a spammed thread cannot crowd out the rest.
struct BriefSection: View {

    let topic: Topic
    /// Sources with their own block on this screen. Kept out of the numbered
    /// rows, kept in the summary.
    var excluding: Set<String> = []
    var onOpen: (Article) -> Void

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var read: ReadStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var markets: MarketStore
    @EnvironmentObject private var live: LiveStore
    @EnvironmentObject private var summaries: SummaryStore

    /// How far back the brief looks. Long enough to have something overnight,
    /// short enough that "just happened" is not a lie.
    private static let window: TimeInterval = 12 * 3600

    private var candidates: [Article] {
        let sources = catalog.sources(reaching: topic)
        let cutoff = Date().addingTimeInterval(-BriefSection.window)
        return feed.articles(for: topic, from: sources)
            .filter { $0.sortDate > cutoff }
    }

    /// The numbered rows: newest first, one per source, nothing repeated, and
    /// nothing from a source that has its own block on this screen.
    private var items: [Article] {
        var seenSources = Set<String>()
        var picked: [Article] = []

        for article in candidates where !excluding.contains(article.sourceID) {
            guard seenSources.insert(article.sourceID).inserted else { continue }
            picked.append(article)
            if picked.count == 5 { break }
        }
        return picked
    }

    /// What the model reads: the newest of everything in the window, including
    /// the sources shown in their own block, capped at three per source so one
    /// busy channel cannot fill the whole prompt.
    private var summaryPool: [Article] {
        var perSource: [String: Int] = [:]
        var picked: [Article] = []

        for article in candidates {
            let used = perSource[article.sourceID] ?? 0
            guard used < 3 else { continue }
            perSource[article.sourceID] = used + 1
            picked.append(article)
            if picked.count == 8 { break }
        }
        return picked
    }

    private var headlines: [SummaryAPI.Headline] {
        summaryPool.map { article in
            SummaryAPI.Headline(
                title: article.displayTitle,
                source: catalog.source(id: article.sourceID)?.name ?? article.sourceID,
                age: article.published?.feedAge
            )
        }
    }

    private var wantsSummary: Bool {
        settings.aiSummaries && settings.hasAnthropicKey
    }

    /// True while the first brief for this topic is still being written.
    ///
    /// Everything below the summary is held back until it lands: a half-drawn
    /// brief where the prose is missing but the numbered list is already there
    /// reads as finished, and then rearranges itself under your thumb.
    private var isAwaitingFirstBrief: Bool {
        wantsSummary
            && summaries.brief(for: topic) == nil
            && summaries.failure(for: topic) == nil
    }

    /// Whether the block has anything to say.
    ///
    /// Keyed to the summary pool when a summary is wanted, not to the rows: on a
    /// quiet night the only thing inside the window can easily be the wire that
    /// the rows exclude, and hiding the whole brief — summary included — because
    /// its *numbered list* came out empty would be exactly backwards.
    private var hasContent: Bool {
        wantsSummary ? !summaryPool.isEmpty : !items.isEmpty
    }

    var body: some View {
        if settings.showBrief, hasContent {
            Section {
                if wantsSummary {
                    summaryRow
                        .listRowSeparator(.hidden)
                        .task(id: SummaryStore.inputKey(for: summaryPool)) {
                            await summaries.refreshIfNeeded(topic: topic,
                                                            articles: summaryPool,
                                                            headlines: headlines)
                        }
                }

                if !isAwaitingFirstBrief {
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

    /// The generated bullets, or the fact that they are being written, or why
    /// there are none.
    @ViewBuilder
    private var summaryRow: some View {
        if let brief = summaries.brief(for: topic) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(SummaryAPI.bullets(from: brief.text).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(TopicTheme.accent(topic))
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(line)
                            .font(.system(size: 14))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Text(attribution(for: brief))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
        } else if let failure = summaries.failure(for: topic) {
            Text(failure)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            // Also the state before the request has started: the row has to
            // render *something*, because a row that renders nothing never
            // appears, and a row that never appears never fires the task that
            // would have started the request.
            generating
        }
    }

    /// Says when it was written, or that a newer one is on the way. A plain
    /// `String` rather than a ternary inside the `Text`, which is the shape that
    /// timed out the type checker in Settings.
    private func attribution(for brief: SummaryStore.GeneratedBrief) -> String {
        if summaries.working.contains(topic.rawValue) { return "Updating…" }
        return "Written by Claude · \(brief.generated.feedAge)"
    }

    /// Loud on purpose. This is the only thing on the screen for a second or
    /// two, and "is it broken or is it thinking" is not a question the reader
    /// should have to hold.
    private var generating: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
                .tint(TopicTheme.accent(topic))

            VStack(alignment: .leading, spacing: 1) {
                Text("Writing the brief…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TopicTheme.accent(topic))
                Text("Claude is reading the last \(summaryPool.count) headlines")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
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
