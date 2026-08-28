import SwiftUI

struct ArticleRow: View {
    let article: Article
    let isRead: Bool
    let isSaved: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.headline)
                    .foregroundStyle(isRead ? .secondary : .primary)
                    .lineLimit(3)

                if !article.summary.isEmpty {
                    Text(article.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text(article.sourceName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                    if let published = article.published {
                        Text("· \(published.feedAge)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if isSaved {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            Spacer(minLength: 0)

            if let imageURL = article.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.secondary.opacity(0.1)
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
    }
}
