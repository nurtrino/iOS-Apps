import SwiftUI

enum Palette {
    /// Sampled from the app icon's mark, so the tint and the icon are the same
    /// amber rather than two that nearly match.
    static let accent = Color(red: 0.941, green: 0.569, blue: 0.169)
    static let kicker = Color(red: 0.886, green: 0.369, blue: 0.235)
    static let surface = Color.secondary.opacity(0.10)
    static let surfaceStrong = Color.secondary.opacity(0.18)
    static let hairline = Color.secondary.opacity(0.25)
}

/// An image loaded through `ImageLoader`.
///
/// Note `.task(id:)`. Without the id, swapping a different URL into the same
/// position leaves the view's *identity* unchanged, so the task never re-runs
/// and every row keeps the picture it had before the refresh.
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
                placeholder()
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
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

/// The source name, and the qualifier that says which game or which handle.
struct SourceBadge: View {

    let sourceName: String
    let context: String?
    let age: String?
    var isUnread: Bool = true
    var accent: Color = Palette.accent

    var body: some View {
        HStack(spacing: 5) {
            if isUnread {
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
            }
            Text(sourceName.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(accent)
                .lineLimit(1)

            if let context, !context.isEmpty, context != sourceName {
                Text(context)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            if let age, !age.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(age)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The full-width state a screen shows when it has nothing else to show.
struct StateView: View {

    let systemImage: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }
}

/// The quiet line at the top of a section listing sources that misbehaved.
///
/// Deliberately not an alert and not an error state: the section has content,
/// and a modal about a Telegram timeout on top of forty working articles would
/// be the app shouting about its own plumbing.
struct AdvisoryBanner: View {

    let lines: [String]
    @State private var isExpanded = false

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text(lines.count == 1 ? "1 source needs attention"
                                              : "\(lines.count) sources need attention")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface)
        }
    }
}
