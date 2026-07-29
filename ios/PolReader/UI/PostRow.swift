import SwiftUI

/// One post in a thread.
struct PostRow: View {

    let board: String
    let post: Post
    let node: ThreadNode
    let isCollapsed: Bool
    let descendantCount: Int
    let backlinks: [Int]
    let isNew: Bool
    /// Ancestors of this post in the derived tree. Non-empty only in threaded
    /// mode, where a leading `>>parent` line is redundant with the nesting.
    let ancestors: Set<Int>
    let onToggleCollapse: () -> Void
    let onSelectPost: (Int) -> Void
    let onOpenAttachment: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @State private var spoilersRevealed = false

    /// The comment with any redundant parent-quote line removed.
    ///
    /// On a flat board `>>123` *is* how you address someone. Drawn underneath
    /// the post it answers, that line says nothing the layout hasn't already
    /// said — so it goes, exactly as a Reddit or HN reply carries no "re:" line.
    /// Only whole lines pointing solely at ancestors are dropped; see
    /// `CommentMarkup.isQuoteOnlyParagraph`.
    private var blocks: [CommentBlock] {
        let parsed = CommentParserCache.shared.blocks(for: post.comment)
        guard !ancestors.isEmpty else { return parsed }

        var remaining = parsed[...]
        while let first = remaining.first,
              case .paragraph(let paragraph) = first,
              CommentMarkup.isQuoteOnlyParagraph(paragraph, targeting: ancestors) {
            remaining = remaining.dropFirst()
        }
        return Array(remaining)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            rails
            VStack(alignment: .leading, spacing: 7) {
                header
                if !isCollapsed {
                    content
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .background(alignment: .leading) {
            if isNew {
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: 3)
            }
        }
    }

    // MARK: - Indentation

    /// One rail per level of nesting, capped — an unbounded back-and-forth
    /// would otherwise squeeze the text to nothing on a phone. The rails are
    /// tappable, which is the fastest way to collapse a long argument.
    private var rails: some View {
        HStack(spacing: 0) {
            ForEach(0..<node.indentDepth, id: \.self) { level in
                Rectangle()
                    .fill(railColor(level))
                    .frame(width: 2)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture(perform: onToggleCollapse)
            }
        }
    }

    private func railColor(_ level: Int) -> Color {
        let hues: [Double] = [0.30, 0.55, 0.08, 0.78, 0.14, 0.62, 0.90, 0.45]
        return Color(hue: hues[level % hues.count], saturation: 0.42, brightness: 0.72)
            .opacity(0.5)
    }

    // MARK: - Header

    /// Only the header toggles collapse. A tap gesture over the whole row
    /// competes with the links inside the comment body, and the links lose.
    private var header: some View {
        Button(action: onToggleCollapse) {
            VStack(alignment: .leading, spacing: 3) {
                if post.isOP, let subject = post.subject {
                    Text(subject)
                        .font(.system(size: 17 * settings.textScale, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .lineLimit(3)
                }

                HStack(spacing: 6) {
                    if let label = post.capcode.label {
                        Text(label)
                            .font(.system(size: 10 * settings.textScale, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Palette.deadlink.opacity(0.85))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    } else if !post.isAnonymous {
                        Text(post.name)
                            .font(.system(size: 12 * settings.textScale, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                    }

                    if let trip = post.trip {
                        Text(trip)
                            .font(.system(size: 11 * settings.textScale, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if settings.showPosterIDs, let posterID = post.posterID {
                        Text(posterID)
                            .font(.system(size: 10 * settings.textScale, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Palette.posterIDColor(posterID))
                            .foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                    if settings.showCountryFlags {
                        FlagBadge(board: board, post: post)
                    }

                    Text(RelativeTime.string(from: post.time))
                        .font(.system(size: 11 * settings.textScale))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    if isCollapsed && descendantCount > 0 {
                        Text("+\(descendantCount)")
                            .font(.system(size: 11 * settings.textScale, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(Capsule())
                    }

                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let attachment = post.attachment {
            attachmentView(attachment)
        }

        if !blocks.isEmpty {
            CommentBody(
                blocks: blocks,
                textScale: settings.textScale,
                spoilersRevealed: spoilersRevealed || settings.revealSpoilersAutomatically
            )
            .onTapGesture {
                // Tapping the body reveals spoilers in this post only. Links
                // inside the text keep their own tap handling.
                if !spoilersRevealed { spoilersRevealed = true }
            }
        }

        if !backlinks.isEmpty {
            replyLinks
        }
    }

    /// The OP's media is the thread's main image, so it gets rendered large and
    /// uncropped. Replies keep a compact thumbnail beside their metadata.
    @ViewBuilder
    private func attachmentView(_ attachment: Attachment) -> some View {
        if post.isOP {
            VStack(alignment: .leading, spacing: 4) {
                PostThumbnail(
                    board: board,
                    attachment: attachment,
                    mode: settings.thumbnailMode,
                    revealSpoilers: settings.revealSpoilersAutomatically,
                    layout: .fill(maxHeight: 420),
                    useFullImage: true
                )
                .onTapGesture(perform: onOpenAttachment)

                attachmentCaption(attachment)
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                PostThumbnail(
                    board: board,
                    attachment: attachment,
                    mode: settings.thumbnailMode,
                    revealSpoilers: settings.revealSpoilersAutomatically,
                    layout: .square(96)
                )
                .onTapGesture(perform: onOpenAttachment)

                attachmentCaption(attachment)
                Spacer(minLength: 0)
            }
        }
    }

    private func attachmentCaption(_ attachment: Attachment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(attachment.displayName)
                .font(.system(size: 10 * settings.textScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(attachment.dimensionsText) · \(attachment.formattedFileSize)")
                .font(.system(size: 10 * settings.textScale))
                .foregroundStyle(.tertiary)
        }
    }

    /// The backlinks the API does not provide: who replied to this post.
    ///
    /// In threaded mode these are mostly visible as nesting already, so they
    /// only earn their space when a reply lives elsewhere in the tree — which
    /// happens whenever someone quotes several posts at once.
    private var replyLinks: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(backlinks, id: \.self) { reply in
                        Button {
                            onSelectPost(reply)
                        } label: {
                            Text(">>\(reply)")
                                .font(.system(size: 11 * settings.textScale, design: .monospaced))
                                .foregroundStyle(Palette.quotelink)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
