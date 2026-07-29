import SwiftUI
import SafariServices

/// In-app browser for links leaving the app.
///
/// Reader mode is left off deliberately. Half the feeds here carry the full
/// article already, so the app's own reader is the better path for those, and
/// the reason to open the web page at all is usually to see what the site
/// actually published — comments, embeds, the live blog — which Safari's reader
/// strips out.
struct SafariSheet: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.preferredControlTintColor = UIColor(Palette.accent)
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Wraps a URL so it can drive `.sheet(item:)`.
///
/// `URL` is `Identifiable` only from iOS 16 in some SDKs and its `id` would be
/// the URL itself either way; a wrapper keeps the intent obvious and works
/// everywhere.
struct WebLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
