import SwiftUI

/// The next few US data releases.
///
/// Generated on device — see `EconCalendar` for why there is no feed behind it.
/// The important detail in this view is that approximate dates are *shown* as
/// approximate. A calendar that renders a guess and a published date
/// identically is worse than no calendar, because it is trusted the same.
struct CalendarStrip: View {

    @State private var isExpanded = false

    private var events: [EconEvent] {
        EconCalendar.upcoming(limit: isExpanded ? 12 : 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("CALENDAR")
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(0.8)
                        .foregroundStyle(TopicTheme.accent(.economics))
                    Spacer()
                    Text(isExpanded ? "Less" : "More")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            VStack(spacing: 0) {
                ForEach(events) { event in
                    EventRow(event: event)
                    if event.id != events.last?.id {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if isExpanded {
                Text("Dates marked ~ follow the usual pattern and can move by a day or two. "
                     + "FOMC dates are the Fed's published schedule.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

private struct EventRow: View {

    let event: EconEvent

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 1) {
                Text(dayLabel)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(event.isToday ? TopicTheme.accent(.economics) : .secondary)
                Text(dateLabel)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(event.isPast ? .tertiary : .primary)
            }
            .frame(width: 38)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if event.precision == .approximate {
                        Text("~")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(event.title)
                        .font(.system(size: 13, weight: event.importance == .major ? .semibold : .regular))
                        .foregroundStyle(event.isPast ? .secondary : .primary)
                        .lineLimit(1)
                }
                Text("\(event.agency) · \(timeLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if event.importance == .major {
                Circle()
                    .fill(TopicTheme.accent(.economics))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(event.isToday ? TopicTheme.wash(.economics) : Color.clear)
    }

    private var dayLabel: String {
        if event.isToday { return "TODAY" }
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: event.date).uppercased()
    }

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("d")
        return formatter.string(from: event.date)
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: event.date)
    }
}
