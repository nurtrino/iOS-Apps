import Foundation

/// Which streams are on right now.
///
/// Checking is deliberately unequal. A channel with a schedule is only checked
/// around its airtime — there is no point asking whether a nightly show is live
/// at nine in the morning — while an unscheduled one is checked whenever the
/// War screen is open. That keeps a screen with four channels on it from firing
/// four requests a minute, all day, to answer "no".
@MainActor
final class LiveStore: ObservableObject {

    @Published private(set) var channels: [LiveChannel]
    @Published private(set) var states: [String: LiveState] = [:]
    @Published private(set) var isChecking = false

    /// Resolved `UC…` ids for channels configured by handle, so the resolution
    /// scrape happens once per install rather than once per refresh.
    private var resolvedIDs: [String: String] = [:]

    private let channelsFile = "live-channels"
    private let resolvedFile = "live-resolved"

    /// How long a check stays good. Short, because the whole point is knowing
    /// something started.
    private let freshness: TimeInterval = 90

    init(load: Bool = true) {
        guard load else {
            channels = LiveCatalog.defaults
            return
        }
        let stored = DiskStore.load([LiveChannel].self, from: channelsFile)
        if let stored, !stored.isEmpty {
            let known = Set(stored.map(\.id))
            channels = stored + LiveCatalog.defaults.filter { !known.contains($0.id) }
        } else {
            channels = LiveCatalog.defaults
        }
        resolvedIDs = DiskStore.load([String: String].self, from: resolvedFile) ?? [:]
    }

    var enabledChannels: [LiveChannel] {
        channels.filter(\.isEnabled)
    }

    /// Live first, then whatever is on soonest, then the rest.
    ///
    /// The ordering is the feature: a "monitoring the situation" screen should
    /// put what is actually happening at the left edge without anyone having to
    /// scroll for it.
    var sortedChannels: [LiveChannel] {
        enabledChannels.sorted { left, right in
            let leftLive = states[left.id]?.isLive ?? false
            let rightLive = states[right.id]?.isLive ?? false
            if leftLive != rightLive { return leftLive }

            let leftNext = left.schedule?.nextAirtime() ?? Date.distantFuture
            let rightNext = right.schedule?.nextAirtime() ?? Date.distantFuture
            if leftNext != rightNext { return leftNext < rightNext }
            return left.name < right.name
        }
    }

    var liveNow: [LiveChannel] {
        sortedChannels.filter { states[$0.id]?.isLive == true }
    }

    func state(for channel: LiveChannel) -> LiveState? {
        states[channel.id]
    }

    // MARK: - Checking

    func refresh(force: Bool = false) async {
        let due = enabledChannels.filter { channel in
            // X cannot be checked at all — there is no unauthenticated way to
            // ask whether an account is live — so those cards are always a
            // link out and never claim to know.
            guard channel.platform == .youtube else { return false }
            guard force || channel.shouldCheckNow else { return false }
            guard let last = states[channel.id] else { return true }
            return force || Date().timeIntervalSince(last.checked) >= freshness
        }
        guard !due.isEmpty else { return }

        isChecking = true
        defer { isChecking = false }

        await withTaskGroup(of: (String, LiveState).self) { group in
            for channel in due {
                group.addTask {
                    guard let state = try? await YouTubeLive.check(reference: channel.reference) else {
                        return (channel.id, LiveState.offline())
                    }
                    return (channel.id, state)
                }
            }
            for await (id, state) in group {
                states[id] = state
            }
        }
    }

    /// Resolves and caches the `UC…` id for a channel given by handle.
    func channelID(for channel: LiveChannel) async -> String? {
        if let cached = resolvedIDs[channel.id] { return cached }
        guard let resolved = await YouTubeLive.resolveChannelID(reference: channel.reference) else {
            return nil
        }
        resolvedIDs[channel.id] = resolved
        DiskStore.save(resolvedIDs, to: resolvedFile)
        return resolved
    }

    // MARK: - Editing

    func setEnabled(_ enabled: Bool, channelID id: String) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].isEnabled = enabled
        persist()
    }

    func update(_ channel: LiveChannel) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        channels[index] = channel
        persist()
    }

    func resetToDefaults() {
        channels = LiveCatalog.defaults
        states = [:]
        persist()
    }

    private func persist() {
        DiskStore.save(channels, to: channelsFile)
    }
}
