import AVFoundation
import SwiftUI
import UIKit

/// An image held in the transcript, fetched on demand.
///
/// `AsyncImage` cannot be used: the endpoint needs the server's `Authorization` header and may sit
/// behind a node proxy, neither of which a bare URL load provides. The fetch therefore goes through
/// `APIClient` like every other request.
struct TranscriptImageView: View {
    let sessionID: String
    let reference: TranscriptBlock.ImageRef
    /// Tapping opens the full-size viewer; nil renders a non-interactive thumbnail.
    var onOpen: ((UIImage) -> Void)?
    /// Bounds the thumbnail's height; width follows the image's aspect so a strip of mixed
    /// shapes stays tidy.
    var maxHeight: CGFloat = 150

    @Environment(AppModel.self) private var model
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                // `scaledToFit`, not `scaledToFill`: a filled thumbnail crops a screenshot to a
                // square and hides most of what the user attached.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    }
                    .onTapGesture { onOpen?(image) }
                    .accessibilityIdentifier("transcript.image")
            } else {
                placeholder
            }
        }
        .task(id: reference.ref) { await load() }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .frame(width: maxHeight * 1.4, height: maxHeight)
            .overlay {
                if failed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .accessibilityIdentifier(failed ? "transcript.image.failed" : "transcript.image.loading")
    }

    private func load() async {
        if image != nil { return }
        if let cached = TranscriptImageCache.shared.image(for: reference.ref) {
            image = cached
            return
        }
        guard let api = model.apiClient else { failed = true; return }
        do {
            let data = try await api.transcriptImage(id: sessionID, ref: reference.ref, scope: model.scope)
            guard let decoded = UIImage(data: data) else { failed = true; return }
            TranscriptImageCache.shared.store(decoded, for: reference.ref)
            image = decoded
        } catch {
            failed = true
        }
    }
}

/// Small in-memory cache so scrolling past an image twice does not refetch it.
///
/// Transcript entries are immutable once written, so a ref always resolves to the same bytes and
/// the cache never needs invalidating. `NSCache` evicts under pressure on its own, which is what
/// keeps a long conversation full of screenshots from growing without bound.
@MainActor
final class TranscriptImageCache {
    static let shared = TranscriptImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for ref: String) -> UIImage? { cache.object(forKey: ref as NSString) }

    func store(_ image: UIImage, for ref: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: ref as NSString, cost: cost)
    }
}

/// Full-screen image: fitted to the bounds, pinch to zoom, drag to pan.
///
/// ⚠️ Backed by a real `UIScrollView` rather than `scaleEffect` inside a SwiftUI `ScrollView`.
/// `scaleEffect` scales the rendering but not the layout, so the content never becomes larger than
/// the viewport and there is nothing to pan — zooming worked and panning silently did not.
/// `UIScrollView` also gives momentum, rubber-banding and double-tap-to-zoom for free.
struct TranscriptImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZoomableImage(image: image)
                .ignoresSafeArea(edges: .bottom)
                .background(Color.black)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(
                            item: Image(uiImage: image),
                            preview: SharePreview("Image", image: Image(uiImage: image))
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                .toolbarBackground(.visible, for: .navigationBar)
        }
        .accessibilityIdentifier("transcript.imageViewer")
    }
}

/// `UIScrollView` + `UIImageView`, fitted to the viewport.
///
/// ⚠️ The fit runs in `layoutSubviews`, NOT in `updateUIView`. SwiftUI calls `updateUIView` on its
/// own update cycle, which does not coincide with UIKit laying the scroll view out — the first
/// call arrives while bounds are still zero or provisional, so a fit computed there is against the
/// wrong size and the image opens wildly zoomed instead of fitted. `layoutSubviews` is the only
/// point where the real viewport is known, and it also fires on rotation for free.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> FittingScrollView {
        let scrollView = FittingScrollView()
        scrollView.configure(with: image)
        return scrollView
    }

    func updateUIView(_ scrollView: FittingScrollView, context: Context) {
        scrollView.configure(with: image)
    }
}

/// A scroll view that keeps one image fitted and centred, and zoomable up to 8×.
final class FittingScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var fittedForBounds: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        maximumZoomScale = 8
        minimumZoomScale = 1
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .black
        contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("FittingScrollView is created in code only") }

    func configure(with image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        // Force a re-fit: a different image almost certainly has a different aspect ratio.
        fittedForBounds = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }

        // Re-fit only when the viewport itself changed. Doing it on every pass would snap the
        // user's zoom back to 1 while they were pinching.
        if bounds != fittedForBounds {
            fittedForBounds = bounds
            zoomScale = 1
            let fitted = AVMakeRect(aspectRatio: image.size, insideRect: bounds)
            imageView.frame = CGRect(origin: .zero, size: fitted.size)
            contentSize = fitted.size
        }
        centreContent()
    }

    /// Keeps the image centred while it is smaller than the viewport, which is the fitted state.
    private func centreContent() {
        let extraX = max(0, (bounds.width - imageView.frame.width) / 2)
        let extraY = max(0, (bounds.height - imageView.frame.height) / 2)
        contentInset = UIEdgeInsets(top: extraY, left: extraX, bottom: extraY, right: extraX)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centreContent() }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        // Zoom toward the tapped point, so double-tapping a detail brings that detail into view.
        let point = recognizer.location(in: imageView)
        let scale = min(maximumZoomScale, 3)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }
}
