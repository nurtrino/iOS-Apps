import SwiftUI

/// The Forex Factory calendar: two weeks of releases, grouped by day.
struct CalendarScreen: View {

    @EnvironmentObject private var calendar: CalendarStore
    @EnvironmentObject private var settings: SettingsStore

    /// The floor a release must clear to show. Low includes everything.
    @State private var minimumImpact: Impact = .low
    /// nil means every currency.
    @State private var currencyFilter: String?

    var body: some View {
        content
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { impactMenu }
            }
            .refreshable { await calendar.refresh(settings: settings.snapshot) }
            .task { await calendar.refreshIfStale(settings: settings.snapshot) }
    }

    @ViewBuilder
    private var content: some View {
        switch calendar.phase {
        case .idle, .loading:
            LoadingView(label: "Loading the week…")
        case .failed(let message):
            ErrorView(message: message) {
                Task { await calendar.refresh(settings: settings.snapshot) }
            }
        case .loaded:
            VStack(spacing: 0) {
                currencyChips
                if grouped.isEmpty {
                    EmptyStateView(
                        systemImage: "calendar.badge.exclamationmark",
                        title: "Nothing scheduled",
                        message: "No events match the current filters.")
                } else {
                    eventList
                }
            }
        }
    }

    private var currencyChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(label: "All", selected: currencyFilter == nil) {
                    currencyFilter = nil
                }
                ForEach(calendar.currencies, id: \.self) { currency in
                    chip(label: currency, selected: currencyFilter == currency) {
                        currencyFilter = currencyFilter == currency ? nil : currency
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func chip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let events: [EconEvent]
        var id: Date { day }
    }

    private var eventList: some View {
        List {
            ForEach(grouped) { group in
                Section {
                    ForEach(group.events) { event in
                        EventRow(event: event)
                    }
                } header: {
                    Text(dayLabel(group.day))
                        .foregroundStyle(Calendar.autoupdatingCurrent.isDateInToday(group.day)
                                         ? Color.accentColor : Color.secondary)
                }
            }
        }
        .listStyle(.plain)
    }

    private var filtered: [EconEvent] {
        calendar.events.filter { event in
            guard event.impact >= minimumImpact
                    || (event.impact == .holiday && minimumImpact == .low) else {
                return false
            }
            if let currencyFilter, event.currency != currencyFilter { return false }
            return true
        }
    }

    private var grouped: [DayGroup] {
        let byDay = Dictionary(grouping: filtered) {
            Calendar.autoupdatingCurrent.startOfDay(for: $0.date)
        }
        return byDay.keys.sorted().map { DayGroup(day: $0, events: byDay[$0] ?? []) }
    }

    private func dayLabel(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEEE MMM d")
        if Calendar.autoupdatingCurrent.isDateInToday(day) {
            return "Today · " + formatter.string(from: day)
        }
        return formatter.string(from: day)
    }

    private var impactMenu: some View {
        Menu {
            Picker("Impact", selection: $minimumImpact) {
                Text("All events").tag(Impact.low)
                Text("Medium and up").tag(Impact.medium)
                Text("High only").tag(Impact.high)
            }
        } label: {
            Image(systemName: minimumImpact == .low
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }
}

private struct EventRow: View {
    let event: EconEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            ImpactDot(impact: event.impact)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.currency)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                    Text(event.title)
                        .font(.subheadline)
                        .lineLimit(2)
                }
                if event.forecast != nil || event.previous != nil {
                    HStack(spacing: 10) {
                        if let forecast = event.forecast {
                            Text("F: \(forecast)")
                        }
                        if let previous = event.previous {
                            Text("P: \(previous)")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
        .opacity(event.isPast ? 0.5 : 1)
        .padding(.vertical, 2)
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: event.date)
    }
}
