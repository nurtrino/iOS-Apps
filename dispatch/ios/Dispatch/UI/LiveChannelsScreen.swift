import SwiftUI

/// Manage the streams the War screen watches for.
struct LiveChannelsScreen: View {

    @EnvironmentObject private var live: LiveStore
    @State private var editing: LiveChannel?

    var body: some View {
        List {
            Section {
                ForEach(live.channels) { channel in
                    row(for: channel)
                }
            } header: {
                Text("Channels")
            } footer: {
                Text("YouTube channels are checked for real — the app loads the channel's live "
                     + "page and reads whether it is broadcasting. X cannot be checked at all "
                     + "without an account, so those cards always open X rather than claiming to "
                     + "know.")
            }

            Section {
                Button("Reset to defaults") { live.resetToDefaults() }
            }
        }
        .navigationTitle("Streams")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { channel in
            NavigationStack {
                ScheduleEditor(channel: channel)
            }
        }
        .task { await live.refresh(force: true) }
    }

    private func row(for channel: LiveChannel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: channel.platform.systemImage)
                .font(.system(size: 13))
                .frame(width: 22)
                .foregroundStyle(channel.isEnabled ? TopicTheme.accent(.war) : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(channel.isEnabled ? .primary : .secondary)

                Text(detail(for: channel))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if live.state(for: channel)?.isLive == true {
                HStack(spacing: 3) {
                    LiveDot()
                    Text("LIVE").font(.system(size: 10, weight: .heavy))
                }
                .foregroundStyle(.red)
            }

            if channel.schedule != nil {
                Button {
                    editing = channel
                } label: {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Toggle("", isOn: Binding(
                get: { channel.isEnabled },
                set: { live.setEnabled($0, channelID: channel.id) }
            ))
            .labelsHidden()
        }
    }

    private func detail(for channel: LiveChannel) -> String {
        if let schedule = channel.schedule,
           let next = schedule.nextAirtimeDescription() {
            return next
        }
        return channel.blurb
    }
}

/// When a scheduled show airs.
///
/// Editable because show times move, and because the app cannot discover them —
/// the schedule only decides when checking starts, so getting it slightly wrong
/// costs a late card rather than a wrong one.
struct ScheduleEditor: View {

    @State var channel: LiveChannel
    @EnvironmentObject private var live: LiveStore
    @Environment(\.dismiss) private var dismiss

    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        Form {
            if let schedule = channel.schedule {
                Section {
                    ForEach(1...7, id: \.self) { weekday in
                        Button {
                            toggle(weekday: weekday)
                        } label: {
                            HStack {
                                Text(ScheduleEditor.weekdayNames[weekday - 1])
                                    .foregroundStyle(.primary)
                                Spacer()
                                if schedule.weekdays.contains(weekday) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(TopicTheme.accent(.war))
                                }
                            }
                        }
                    }
                } header: {
                    Text("Airs on")
                }

                Section {
                    Stepper(value: Binding(
                        get: { channel.schedule?.startHour ?? 22 },
                        set: { channel.schedule?.startHour = $0; save() }
                    ), in: 0...23) {
                        LabeledContent("Start hour", value: String(format: "%02d:00", schedule.startHour))
                    }

                    Stepper(value: Binding(
                        get: { channel.schedule?.durationMinutes ?? 180 },
                        set: { channel.schedule?.durationMinutes = $0; save() }
                    ), in: 30...360, step: 30) {
                        LabeledContent("Runs for", value: "\(schedule.durationMinutes / 60)h")
                    }
                } header: {
                    Text("Time")
                } footer: {
                    Text("Times are in \(schedule.timeZoneIdentifier.replacingOccurrences(of: "_", with: " ")), "
                         + "the broadcaster's timezone. The card appears "
                         + "\(schedule.leadMinutes) minutes early and the app starts checking then.")
                }
            }
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func toggle(weekday: Int) {
        guard var schedule = channel.schedule else { return }
        if schedule.weekdays.contains(weekday) {
            schedule.weekdays.remove(weekday)
        } else {
            schedule.weekdays.insert(weekday)
        }
        channel.schedule = schedule
        save()
    }

    private func save() {
        live.update(channel)
    }
}
