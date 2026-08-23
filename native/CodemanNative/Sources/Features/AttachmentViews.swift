import AVFoundation
import SwiftUI
import UIKit

/// One in-flight or finished image upload.
struct AttachmentUpload: Identifiable, Sendable {
    struct Payload: Sendable {
        var data: Data
        var filename: String
        var mime: String
    }

    enum State: Sendable, Equatable {
        case queued
        case uploading
        case finished(path: String)
        case failed(String)
    }

    let id = UUID()
    var filename: String
    var byteCount: Int
    var state: State = .queued
    /// Retained while an upload could still be retried, and cleared on success so a finished
    /// image is not held in memory for the life of the pane.
    var payload: Payload?
}

/// Horizontal strip of upload chips with per-item progress and retry.
struct UploadTray: View {
    @Binding var uploads: [AttachmentUpload]
    let onRetry: (AttachmentUpload) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(uploads) { upload in
                    chip(for: upload)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 56)
        .accessibilityIdentifier("uploads.tray")
    }

    @ViewBuilder
    private func chip(for upload: AttachmentUpload) -> some View {
        HStack(spacing: 6) {
            switch upload.state {
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
            case .uploading:
                ProgressView().controlSize(.mini)
            case .finished:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(upload.filename)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(for: upload))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 150, alignment: .leading)

            if case .failed = upload.state {
                Button("Retry") { onRetry(upload) }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }

            Button {
                uploads.removeAll { $0.id == upload.id }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Dismiss \(upload.filename)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func detail(for upload: AttachmentUpload) -> String {
        switch upload.state {
        case .queued: "Queued · \(formatted(upload.byteCount))"
        case .uploading: "Uploading · \(formatted(upload.byteCount))"
        case .finished: "Path added to the message"
        case let .failed(message): message
        }
    }

    private func formatted(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Attachment source picker.
///
/// Photos come through `PhotosPicker`, which runs out of process — so the app needs **no**
/// `NSPhotoLibraryUsageDescription` and the user grants nothing library-wide. The camera is the
/// only source that needs a permission, and it is requested only when the user taps it.
struct AttachmentSourceSheet: View {
    let onPickPhotos: () -> Void
    let onPickFiles: () -> Void
    let onCamera: () -> Void
    let onPaste: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button { onPickPhotos() } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("attach.photos")

                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { onCamera() } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    .accessibilityIdentifier("attach.camera")
                }

                Button { onPickFiles() } label: {
                    Label("Files", systemImage: "folder")
                }
                .accessibilityIdentifier("attach.files")

                Button { onPaste() } label: {
                    Label("Paste Image", systemImage: "doc.on.clipboard")
                }
                .accessibilityIdentifier("attach.paste")
            }
            .navigationTitle("Attach")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Minimal camera capture. Uses `UIImagePickerController` because it needs no custom capture
/// pipeline and inherits the system's own permission prompt.
struct CameraCaptureView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, dismiss: { dismiss() }) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data) -> Void
        private let dismiss: () -> Void

        init(onCapture: @escaping (Data) -> Void, dismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.9) {
                onCapture(data)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
