import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A growing text view whose system edit menu accepts images and files, not just text.
///
/// ⚠️ SwiftUI's `TextField` cannot do this. Its Paste command inserts text and silently drops any
/// other flavour on the pasteboard, and `onPasteCommand` — the modifier that would intercept it —
/// is **macOS-only**. The system menu (Select / Select All / Paste / AutoFill) is driven by
/// `UIResponder.canPerformAction` and `paste(itemProviders:)`, so accepting an image there means
/// owning a `UITextView` and declaring a `pasteConfiguration`.
struct PastingTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Called for each non-text item pasted or dropped.
    var onAttach: ([NSItemProvider]) -> Void
    /// Height is reported back so the composer can grow with the content.
    var onHeightChange: (CGFloat) -> Void

    /// Roughly eight lines, matching the previous `lineLimit(1...8)`.
    static let maxHeight: CGFloat = 160

    func makeUIView(context: Context) -> AttachmentTextView {
        let view = AttachmentTextView()
        view.delegate = context.coordinator
        view.onAttach = onAttach
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        // ⚠️ Both are required or the view grows sideways instead of wrapping. A UITextView's
        // intrinsic width is its longest unbroken line, and `UIViewRepresentable` hands that up as
        // the ideal width — so SwiftUI happily makes the composer wider than the screen rather
        // than wrapping the text. Refusing to expand horizontally, and refusing to compress, is
        // what forces the layout width onto the text container.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.textContainer.widthTracksTextView = true
        view.adjustsFontForContentSizeCategory = true
        // Accept what the composer can actually upload. Declaring it is what makes the system
        // offer Paste for a copied image or file at all.
        let configuration = UIPasteConfiguration(forAccepting: UIImage.self)
        configuration.addTypeIdentifiers(forAccepting: URL.self)
        view.pasteConfiguration = configuration
        view.placeholderLabel.text = placeholder
        // ⚠️ ONE accessibility element, not a tree. A `UITextView` exposes every text range, link
        // and layout fragment as its own element, and that subtree is large enough that XCUITest's
        // element resolution stalls for MINUTES on any query that has to walk it — which is why
        // the jump-to-latest UI test was disabled, and therefore why that button shipped broken
        // three times running. A composer is conceptually a single control; collapsing it costs
        // VoiceOver nothing and gives the harness back a tree it can traverse.
        view.isAccessibilityElement = true
        view.accessibilityTraits = .searchField
        view.accessibilityLabel = placeholder
        view.accessibilityIdentifier = "composer.field"
        return view
    }

    func updateUIView(_ view: AttachmentTextView, context: Context) {
        if view.text != text { view.text = text }
        // Keep the text container pinned to the view's real width; without this a width change
        // (rotation, keyboard) leaves the previous wrap points in place.
        view.textContainer.size.width = max(view.bounds.width - view.textContainerInset.left
                                            - view.textContainerInset.right, 1)
        view.onAttach = onAttach
        view.placeholderLabel.isHidden = !view.text.isEmpty
        context.coordinator.reportHeight(of: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: PastingTextView
        private var lastReported: CGFloat = 0

        init(_ parent: PastingTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? AttachmentTextView)?.placeholderLabel.isHidden = !textView.text.isEmpty
            reportHeight(of: textView)
        }

        func reportHeight(of textView: UITextView) {
            let width = textView.bounds.width
            guard width > 0 else { return }
            let fitted = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            let clamped = min(max(fitted, 36), PastingTextView.maxHeight)
            // Past the cap the view has to scroll, or long messages would grow without bound.
            textView.isScrollEnabled = fitted > PastingTextView.maxHeight
            guard abs(clamped - lastReported) > 0.5 else { return }
            lastReported = clamped
            DispatchQueue.main.async { self.parent.onHeightChange(clamped) }
        }
    }
}

/// The `UITextView` that actually accepts the paste.
final class AttachmentTextView: UITextView {
    var onAttach: (([NSItemProvider]) -> Void)?

    let placeholderLabel: UILabel = {
        let label = UILabel()
        label.textColor = .placeholderText
        label.font = .preferredFont(forTextStyle: .body)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("AttachmentTextView is created in code only") }

    /// ⚠️ Enable Paste whenever the pasteboard holds ANYTHING we can take. Without this override
    /// the menu offers Paste only for text, so a copied screenshot appears to be un-pasteable.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            let board = UIPasteboard.general
            if board.hasImages || board.hasURLs { return true }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Text pastes normally; anything else is handed to the composer as an attachment.
    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if board.hasImages || board.hasURLs, !board.hasStrings {
            onAttach?(board.itemProviders)
            return
        }
        // Mixed content: take the text inline and the rest as attachments, which is what a user
        // copying a screenshot plus a caption expects.
        if board.hasImages || board.hasURLs {
            onAttach?(board.itemProviders.filter { !$0.canLoadObject(ofClass: String.self) })
        }
        super.paste(sender)
    }

    /// The same acceptance, for a drag-and-drop onto the composer.
    override func paste(itemProviders: [NSItemProvider]) {
        onAttach?(itemProviders)
    }
}
