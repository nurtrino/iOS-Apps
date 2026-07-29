import SwiftUI

/// A `GIFPlayerView` in SwiftUI's terms.
private struct AnimatedImage: UIViewRepresentable {

    let data: Data
    var contentMode: ContentMode = .fit

    func makeUIView(context: Context) -> GIFPlayerView {
        let view = GIFPlayerView()
        view.play(data)
        return view
    }

    func updateUIView(_ view: GIFPlayerView, context: Context) {
        view.layer.contentsGravity = contentMode == .fill ? .resizeAspectFill : .resizeAspect
        view.clipsToBounds = contentMode == .fill
        // A no-op unless the bytes actually changed; this runs on every render
        // of the enclosing view, which during a dismiss drag is every frame.
        view.play(data)
    }

    static func dismantleUIView(_ view: GIFPlayerView, coordinator: ()) {
        view.stop()
    }
}

/// An animated GIF loaded from the network.
///
/// Deliberately a sibling of `RemoteImage` rather than a mode of it: the two
/// need different things from the loader. An image wants the decoded, display-
/// ready `UIImage` held in the image cache; an animation wants the file's bytes,
/// because the animator reads the frames itself.
///
/// It falls back to `RemoteImage` for a `.gif` that turns out to hold a single
/// frame — there are plenty of those — so those still take the cached path.
struct RemoteAnimatedImage<Placeholder: View>: View {

    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var data: Data?
    @State private var isAnimated = false
    @State private var failed = false

    var body: some View {
        ZStack {
            if let data, isAnimated {
                AnimatedImage(data: data, contentMode: contentMode)
            } else if data != nil || failed {
                RemoteImage(url: url, contentMode: contentMode, placeholder: placeholder)
            } else {
                placeholder()
            }
        }
        // Keyed on the URL for the same reason `RemoteImage` is: without it a
        // swapped URL at the same position in the hierarchy never reloads.
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else {
            data = nil
            failed = true
            return
        }
        data = nil
        failed = false
        do {
            let loaded = try await ImageLoader.shared.data(for: url)
            guard !Task.isCancelled else { return }
            isAnimated = GIFSupport.isAnimated(loaded)
            data = loaded
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

extension RemoteAnimatedImage where Placeholder == AnyView {
    init(url: URL?, contentMode: ContentMode = .fill) {
        self.init(url: url, contentMode: contentMode) {
            AnyView(Color.secondary.opacity(0.12))
        }
    }
}
