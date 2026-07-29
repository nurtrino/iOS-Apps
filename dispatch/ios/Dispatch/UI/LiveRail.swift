import SwiftUI

/// The row of stream cards across the top of the War screen.
///
/// Ordered live-first by `LiveStore`, so the thing that is actually happening
/// is at the left edge without anyone scrolling for it. Channels that are off
/// air still appear, because "back tonight at 10" is more useful on a
/// monitoring screen than an empty space where a card used to be.
struct LiveRail: View {

    @EnvironmentObject private var live: LiveStore

    @Binding var playing: LivePlayback?
    @Binding var webLink: WebLink?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("STREAMS")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(TopicTheme.accent(.war))

                if !live.liveNow.isEmpty {
                    Text("\(live.liveNow.count) live")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                        .foregroundStyle(.white)
                }

                Spacer()

                if live.isChecking {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(live.sortedChannels) { channel in
                        LiveCard(channel: channel,
                                 state: live.state(for: channel),
                                 playing: $playing,
                                 webLink: $webLink)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
        }
        .padding(.top, 8)
    }
}

/// What the player sheet is showing.
struct LivePlayback: Identifiable {
    let channel: LiveChannel
    let state: LiveState
    var id: String { channel.id }
}

struct LiveCard: View {

    let channel: LiveChannel
    let state: LiveState?
    @Binding var playing: LivePlayback?
    @Binding var webLink: WebLink?

    private var isLive: Bool { state?.isLive == true }

    var body: some View {
        Button(action: activate) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnail
                caption
            }
            .frame(width: 208)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isLive ? Color.red.opacity(0.75) : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var thumbnail: some View {
        ZStack {
            if let url = state?.thumbnailURL {
                RemoteImage(url: url)
            } else {
                LinearGradient(colors: [Palette.surfaceStrong, Palette.surface],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: channel.platform.systemImage)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 208, height: 117)
        .clipped()
        .overlay(alignment: .topLeading) { badge }
        .overlay(alignment: .center) {
            if isLive {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(radius: 6)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if isLive {
            HStack(spacing: 4) {
                LiveDot()
                Text("LIVE")
                    .font(.system(size: 10, weight: .heavy))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.7), in: Capsule())
            .foregroundStyle(.white)
            .padding(8)
        } else if channel.platform == .x {
            Text("X")
                .font(.system(size: 10, weight: .heavy))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.black.opacity(0.7), in: Capsule())
                .foregroundStyle(.white)
                .padding(8)
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(channel.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)

            Text(statusLine)
                .font(.system(size: 11))
                .foregroundStyle(isLive ? Color.red : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    /// The one line under the name, and the only place the app admits what it
    /// does and does not know.
    private var statusLine: String {
        if isLive { return state?.title ?? "Live now" }

        if channel.platform == .x {
            // There is no unauthenticated way to ask X whether an account is
            // live, so this card never pretends to know.
            return "Opens in X — live status unavailable"
        }
        if let schedule = channel.schedule,
           let next = schedule.nextAirtimeDescription() {
            return next
        }
        if state == nil { return "Checking…" }
        return "Off air"
    }

    private func activate() {
        if isLive, let state, channel.platform == .youtube {
            playing = LivePlayback(channel: channel, state: state)
            return
        }
        if let url = channel.externalURL {
            webLink = WebLink(url: url)
        }
    }
}
