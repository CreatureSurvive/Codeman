import SwiftUI
import UIKit

/// Selecting, copying and opening links from terminal output.
///
/// The grid is a Metal surface: it has no selection handles, no magnifier, no edit menu and no
/// tappable links, and it cannot get them — those are `UITextView` behaviours and there is no
/// text view underneath. Long-pressing the terminal therefore brings the visible text *here*, into
/// a real read-only text view, where iOS's own selection works exactly as it does everywhere else.
///
/// The word under the finger arrives pre-selected, so the common case — long-press a path, tap
/// Copy — is two gestures. `dataDetectorTypes` makes URLs tappable, which is also the only way to
/// open a link from the terminal on a touch device: ghostty's own open-URL action is driven by a
/// pointer click, so a finger never triggers it.
struct TerminalSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let payload: TerminalSelectionPayload

    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            SelectableTextView(text: payload.text, initialSelection: payload.anchorRange)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Terminal Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            UIPasteboard.general.string = payload.text
                            didCopy = true
                        } label: {
                            Label(didCopy ? "Copied" : "Copy All",
                                  systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        }
                        .accessibilityIdentifier("selection.copyAll")
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// A read-only `UITextView` that starts with a selection and detects links.
private struct SelectableTextView: UIViewRepresentable {
    let text: String
    let initialSelection: NSRange?

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        // Selectable **and** not editable is what gives the standard Copy / Look Up / Share menu
        // and the drag handles. `dataDetectorTypes` only applies in this combination.
        view.isSelectable = true
        view.dataDetectorTypes = [.link]
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "selection.text"
        view.text = text

        // Applied after the text so the range is valid, and on the next runloop turn because the
        // layout manager has not measured anything yet — selecting before that scrolls nowhere.
        DispatchQueue.main.async {
            let range = Self.clamp(initialSelection, to: text)
            view.selectedRange = range
            if range.length > 0 {
                view.scrollRangeToVisible(range)
            }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    /// A range the package computed against its own snapshot must still be valid here — an
    /// out-of-bounds `selectedRange` traps rather than being ignored.
    static func clamp(_ range: NSRange?, to text: String) -> NSRange {
        let length = (text as NSString).length
        guard let range, range.location != NSNotFound, range.location <= length else {
            return NSRange(location: 0, length: 0)
        }
        return NSRange(location: range.location, length: min(range.length, length - range.location))
    }
}
