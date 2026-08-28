import SafariServices
import SwiftUI

/// Stories open in an in-app Safari sheet: reader mode, content blockers and
/// shared cookies for free, and dismissing lands back on the feed instead of
/// in another app.
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
