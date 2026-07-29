import SwiftUI

enum Palette {
    static let accent = Color(red: 0.36, green: 0.78, blue: 0.72)
    static let accentDeep = Color(red: 0.20, green: 0.60, blue: 0.58)
    static let surface = Color.secondary.opacity(0.10)
    static let surfaceStrong = Color.secondary.opacity(0.18)
}

/// An image loaded through `ImageLoader`.
///
/// Note `.task(id:)`. Without the id, swapping a different URL into the same
/// position leaves the view's *identity* unchanged, so the task never re-runs
/// and every cell keeps the picture it had before the refresh.
struct RemoteImage<Placeholder: View>: View {

    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            failed = true
            return
        }
        // A file URL is a saved poster frame; loading it synchronously keeps
        // the offline library from flickering on every scroll.
        if url.isFileURL {
            image = await ImageLoader.shared.localImage(at: url)
            failed = image == nil
            return
        }
        if let cached = await ImageLoader.shared.cached(url) {
            image = cached
            failed = false
            return
        }
        image = nil
        failed = false
        do {
            let loaded = try await ImageLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

extension RemoteImage where Placeholder == AnyView {
    init(url: URL?, contentMode: ContentMode = .fill) {
        self.init(url: url, contentMode: contentMode) {
            AnyView(Palette.surface)
        }
    }
}

/// A video thumbnail with its duration badge.
struct Thumbnail: View {
    let url: URL?
    let duration: String
    var isLive: Bool = false
    var cornerRadius: CGFloat = 12

    var body: some View {
        RemoteImage(url: url)
            .aspectRatio(16.0 / 9.0, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if isLive {
                    Text("LIVE")
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                } else if !duration.isEmpty {
                    Text(duration)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.75), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
    }
}

/// The standard list row: large thumbnail, title, channel, metadata.
struct VideoCard: View {
    let video: Video
    let instance: Instance
    var isDownloaded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Thumbnail(
                url: instance.resolve(video.thumbnailPath),
                duration: video.formattedDuration,
                isLive: video.isLive
            )

            HStack(alignment: .top, spacing: 10) {
                if let channel = video.channel {
                    RemoteImage(url: instance.resolve(channel.bestAvatarPath))
                        .frame(width: 34, height: 34)
                        .clipShape(Circle())
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(video.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(video.channel?.displayName ?? video.account?.displayName ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(Format.count(video.views) + " views")
                        if let published = video.publishedAt {
                            Text("·")
                            Text(RelativeTime.string(from: published))
                        }
                        if isDownloaded {
                            Text("·")
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(Palette.accent)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - States

struct LoadingState: View {
    var label: String = "Loading…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(label).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorState: View {
    let message: String
    var systemImage: String = "exclamationmark.triangle"
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            if let retry {
                Button("Try Again", action: retry).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyState: View {
    let title: String
    var message: String?
    var systemImage: String = "tray"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let message {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Formatting

enum Format {
    /// 1.2K, 3.4M — a raw view count is noise at a glance.
    static func count(_ value: Int) -> String {
        switch value {
        case ..<1_000:
            return "\(value)"
        case ..<1_000_000:
            return String(format: "%.1fK", Double(value) / 1_000).replacingOccurrences(
                of: ".0K", with: "K"
            )
        default:
            return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(
                of: ".0M", with: "M"
            )
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}
