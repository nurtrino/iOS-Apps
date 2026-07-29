import SwiftUI

/// What a release actually said, for the calendar entry you tapped.
///
/// The calendar on its own answers "when", and "when" is only half of what
/// someone opens that section for. This is the other half: the last published
/// numbers for the series that release covers, pulled from FRED — which needs no
/// key, so it costs nothing and asks nothing of the reader.
///
/// Two honesty rules run through it. The dates in the calendar are *scheduled*
/// dates, some of them derived from a pattern, while these numbers are for the
/// period already published — so the sheet labels the period rather than
/// implying the number belongs to the date above. And ISM has no free series at
/// all, so it says that instead of showing an empty table.
struct EventDetailSheet: View {

    let event: EconEvent

    @Environment(\.dismiss) private var dismiss

    @State private var readings: [SeriesReading] = []
    @State private var phase = LoadPhase.idle

    private var accent: Color { TopicTheme.accent(.economics) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    schedule

                    if event.hasNumbers {
                        numbers
                    } else {
                        StateView(
                            systemImage: "chart.bar.doc.horizontal",
                            title: "No free series for this one",
                            message: "ISM's index is licensed, so there is no source for the "
                                + "numbers that does not need a paid subscription. The release "
                                + "time above is right."
                        )
                    }

                    if event.hasNumbers {
                        Text(attribution)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }
            .navigationTitle(event.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    // MARK: - Pieces

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .bold))
                Text(scheduleLine)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(accent)

            Text(event.precision == .approximate
                 ? "\(event.agency) · this date follows the usual pattern and can move by a day or two"
                 : "\(event.agency) · published schedule")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var numbers: some View {
        switch phase {
        case .loading, .refreshing:
            HStack(spacing: 9) {
                ProgressView().controlSize(.small).tint(accent)
                Text("Loading the last numbers…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .failed(let message):
            StateView(systemImage: "wifi.slash",
                      title: "Could not load the numbers",
                      message: message,
                      actionTitle: "Try again",
                      action: { Task { await load(force: true) } })

        case .idle, .loaded:
            VStack(alignment: .leading, spacing: 16) {
                ForEach(readings, id: \.series.id) { reading in
                    headlineCard(reading)
                }

                if let primary = readings.first {
                    history(primary)
                }
            }
        }
    }

    private func headlineCard(_ reading: SeriesReading) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(reading.series.title.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            Text(reading.headline)
                .font(.system(size: 32, weight: .bold).monospacedDigit())
                .foregroundStyle(.primary)

            Text(headlineFooter(reading))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if let detail = reading.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func history(_ reading: SeriesReading) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RECENT")
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            ForEach(Array(reading.observations.prefix(8)), id: \.date) { observation in
                HStack {
                    Text(period(observation.date, in: reading.series))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(reading.row(for: observation))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                }
                .padding(.vertical, 7)

                if observation.date != reading.observations.prefix(8).last?.date {
                    Divider()
                }
            }
        }
    }

    // MARK: - Text

    private var scheduleLine: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMdjmm")
        let when = formatter.string(from: event.date)
        if event.isPast { return "Released \(when)" }
        return (event.precision == .approximate ? "Expected ~" : "Due ") + when
    }

    private func headlineFooter(_ reading: SeriesReading) -> String {
        guard let latest = reading.latest else { return reading.headlineCaption }
        return reading.headlineCaption + " · " + period(latest.date, in: reading.series)
    }

    /// The period an observation describes, at the precision it actually has.
    private func period(_ date: Date, in series: FredSeries) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        switch series.period {
        case .monthly:
            formatter.setLocalizedDateFormatFromTemplate("MMMyyyy")
        case .weekly:
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        case .daily:
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        let text = formatter.string(from: date)
        return series.period == .weekly ? "Week of \(text)" : text
    }

    private var attribution: String {
        "Numbers from FRED, Federal Reserve Bank of St. Louis. These are the last figures "
            + "published, which for a monthly release means the previous period — not the date "
            + "above."
    }

    // MARK: - Loading

    private func load(force: Bool = false) async {
        let series = event.kind.series
        guard !series.isEmpty else { return }
        if !force, phase == .loaded { return }

        phase = readings.isEmpty ? .loading : .refreshing

        var collected: [SeriesReading] = []
        var failure: String?

        for entry in series {
            do {
                collected.append(try await FredAPI.shared.reading(for: entry))
            } catch {
                // One missing secondary series should not empty the sheet, so a
                // failure only surfaces when nothing at all arrived.
                failure = (error as? FeedError)?.errorDescription
                    ?? FeedError.from(error).errorDescription
                    ?? "FRED did not answer."
            }
        }

        if collected.isEmpty, let failure {
            phase = .failed(failure)
        } else {
            readings = collected
            phase = .loaded
        }
    }
}
