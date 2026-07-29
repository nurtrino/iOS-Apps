import SwiftUI

/// The catch-up block at the top of a topic.
///
/// Two things, and the second one is optional. A **state line** built from real
/// numbers where the topic has any — on Markets the actual index moves and
/// whether a release has already landed today, which is the specific question
/// that section gets asked at nine in the morning. And, when an Anthropic key is
/// saved and the toggle is on, a **written summary**: a few bullets from the
/// Claude API saying what just happened.
///
/// What it deliberately does *not* contain is headlines. It used to open with
/// five of them, numbered, and they were the same stories as the list directly
/// underneath — the same words twice on one screen, and a wire having a busy
/// hour could fill all five slots with one thread. The list below is the list.
/// The brief says what happened; scrolling says what else.
///
/// The summary reads the newest eight items in the window, capped at three per
/// source so one busy channel cannot fill the prompt (see `SummaryStore` for
/// what is sent and how rarely). No key, no network, or a failed request — the
/// state line stands alone, and where a topic has no numbers either, the block
/// is simply absent.
struct BriefSection: View {

    let topic: Topic

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var feed: FeedStore
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

    /// What the model reads: the newest of everything in the window, capped at
    /// three per source so one busy channel cannot fill the whole prompt.
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

    /// Whether the block has anything to say at all.
    private var hasContent: Bool {
        if wantsSummary && !summaryPool.isEmpty { return true }
        return stateLine != nil
    }

    var body: some View {
        if settings.showBrief, hasContent {
            Section {
                if wantsSummary, !summaryPool.isEmpty {
                    summaryRow
                        .listRowSeparator(.hidden)
                        .task(id: SummaryStore.inputKey(for: summaryPool)) {
                            await summaries.refreshIfNeeded(topic: topic,
                                                            articles: summaryPool,
                                                            headlines: headlines)
                        }
                }

                if let state = stateLine {
                    Text(state)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TopicTheme.accent(topic))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowSeparator(.hidden)
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
