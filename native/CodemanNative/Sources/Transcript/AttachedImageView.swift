import SwiftUI
import UIKit

/// An image the user attached, addressed by its file path.
///
/// ⚠️ Loaded through the ATTACHMENT routes, not the transcript image route. A transcript image is
/// base64 inside the JSONL; an attachment is a real file on the host that the prompt merely names.
/// Registering the path yields an id the app can fetch, and `notify: false` suppresses the
/// `attachment:detected` broadcast — without it, every rendered thumbnail would pop a card on every
/// client announcing a file that is already on screen.
struct AttachedImageView: View {
    let sessionID: String
    let path: String
    var onOpen: ((UIImage) -> Void)?
    var maxHeight: CGFloat = 150

    @Environment(AppModel.self) private var model
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
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
                    .accessibilityIdentifier("transcript.attachedImage")
            } else if failed {
                // Fall back to naming the file rather than showing a broken frame: the path is
                // still the useful thing when the bytes cannot be fetched.
                Label((path as NSString).lastPathComponent, systemImage: "doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                    .accessibilityIdentifier("transcript.attachedImage.failed")
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: maxHeight * 1.4, height: maxHeight)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        if image != nil { return }
        if let cached = TranscriptImageCache.shared.image(for: path) {
            image = cached
            return
        }
        guard let api = model.apiClient else { failed = true; return }
        do {
            let descriptor = try await api.registerAttachment(
                path: path,
                notify: false,
                sessionID: sessionID,
                scope: model.scope
            )
            let data = try await api.attachmentData(id: descriptor.id, sessionID: sessionID, scope: model.scope)
            guard let decoded = UIImage(data: data) else { failed = true; return }
            TranscriptImageCache.shared.store(decoded, for: path)
            image = decoded
        } catch {
            failed = true
        }
    }
}
