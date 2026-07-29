import SwiftUI
import SafariServices

/// In-app browser for links leaving the app.
///
/// The app is read-only, so anything needing an account — replying, reporting,
/// the archive's own search — is a link out to the website rather than a
/// half-working imitation.
struct SafariSheet: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
