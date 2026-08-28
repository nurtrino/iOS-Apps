import SwiftUI
import UserNotifications

struct SettingsScreen: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var calendar: CalendarStore

    @State private var authStatus: UNAuthorizationStatus = .notDetermined

    private static let alertCurrencies = ["USD", "EUR", "GBP", "JPY", "AUD", "CAD", "CHF", "NZD", "CNY"]

    var body: some View {
        List {
            notificationsSection
            eventAlertSection
            sourcesSection
            aboutSection
        }
        .navigationTitle("Settings")
        .task { authStatus = await NotificationManager.shared.authorizationStatus() }
        .onChange(of: settings.eventAlertLevel) { _ in reschedule() }
        .onChange(of: settings.eventLeadMinutes) { _ in reschedule() }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section(
            header: Text("Notifications"),
            footer: Text("Alerts are generated on-device: calendar reminders are scheduled ahead of time, and headline alerts arrive when iOS grants the app a background fetch. Sideloaded builds get no remote push — that needs an Apple push entitlement a self-signed app cannot carry.")
        ) {
            switch authStatus {
            case .notDetermined:
                Button("Enable Notifications") {
                    Task {
                        _ = await NotificationManager.shared.requestAuthorization()
                        authStatus = await NotificationManager.shared.authorizationStatus()
                        reschedule()
                    }
                }
            case .denied:
                Button("Notifications are off — open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            default:
                Label("Notifications enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            }

            Toggle("Breaking headline alerts", isOn: $settings.headlineAlerts)
        }
    }

    private var eventAlertSection: some View {
        Section(
            header: Text("Event Reminders"),
            footer: Text("With no currency selected, every currency alerts. Reminders re-plan themselves whenever the calendar refreshes.")
        ) {
            Picker("Calendar events", selection: $settings.eventAlertLevel) {
                ForEach(EventAlertLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }

            Picker("Remind me", selection: $settings.eventLeadMinutes) {
                Text("At release time").tag(0)
                Text("5 min before").tag(5)
                Text("15 min before").tag(15)
                Text("30 min before").tag(30)
                Text("1 hour before").tag(60)
            }
            .disabled(settings.eventAlertLevel == .off)

            if settings.eventAlertLevel != .off {
                DisclosureGroup("Currencies (\(currencySummary))") {
                    ForEach(Self.alertCurrencies, id: \.self) { currency in
                        Toggle(currency, isOn: currencyBinding(currency))
                    }
                }
            }
        }
    }

    private var currencySummary: String {
        settings.alertCurrenciesOnly.isEmpty
            ? "all"
            : settings.alertCurrenciesOnly.sorted().joined(separator: " ")
    }

    private func currencyBinding(_ currency: String) -> Binding<Bool> {
        Binding(
            get: { settings.alertCurrenciesOnly.contains(currency) },
            set: { on in
                if on {
                    settings.alertCurrenciesOnly.insert(currency)
                } else {
                    settings.alertCurrenciesOnly.remove(currency)
                }
                reschedule()
            }
        )
    }

    private func reschedule() {
        NotificationManager.shared.rescheduleEventReminders(
            events: calendar.events, settings: settings.snapshot)
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        Section(
            header: Text("Sources"),
            footer: Text("The economic calendar comes from Forex Factory and is always on.")
        ) {
            ForEach(FeedCatalog.sources) { source in
                Toggle(source.name, isOn: Binding(
                    get: { settings.isEnabled(source) },
                    set: { settings.toggle(source, on: $0) }
                ))
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            row("Calendar", "Forex Factory")
            row("Market data", "Stooq · ECB (Frankfurter)")
            row("Version", version)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}
