import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Sending from the transcript view.
///
/// ⚠️ This is NOT the composer that was removed from the terminal pane. There, typing goes straight
/// into the Ghostty grid, so a text field was a redundant second input path. The transcript is a
/// rendered document with no keystroke route at all — without this it is read-only, and switching
/// to the terminal just to reply defeats the point of the view.
///
/// Text goes through `POST /api/sessions/:id/input`, so the server owns the send-keys + Enter
/// sequencing. The control pills drive the CLI's own in-session affordances and are gated by
/// `HarnessCapabilities` — see there for why a missing capability hides the control rather than
/// wiring it to a guessed command.
struct TranscriptComposer: View {
    let sessionID: String

    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    /// Backed by `AppModel` rather than `@State` so an unsent message survives leaving the chat.
    private var text: Binding<String> {
        Binding(
            get: { model.composerDraft(for: sessionID) },
            set: { model.setComposerDraft($0, for: sessionID) }
        )
    }
    @State private var isSending = false
    /// Reported by the text view so the composer grows with the message.
    @State private var fieldHeight: CGFloat = 36
    @State private var busyReason: String?
    @State private var permissionMode: PermissionModeReader.Mode?
    @State private var slashCommands: [SlashCommand] = []

    @State private var photoItem: PhotosPickerItem?
    @State private var showingFiles = false
    @State private var showingCamera = false

    private var session: SessionSnapshot? { model.session(id: sessionID) }
    private var mode: SessionMode? { session?.mode }

    var body: some View {
        VStack(spacing: 10) {
            if let matches = visibleSlashCommands, !matches.isEmpty {
                SlashCommandPicker(commands: matches) { command in
                    // Leave a trailing space: most commands take an argument, and the ones that do
                    // not are unaffected by it.
                    text.wrappedValue = "/\(command.name) "
                    focused = true
                }
            }

            if !model.attachments(for: sessionID).isEmpty {
                attachmentChips
            }

            // Field first and full width: with the controls above it the field was boxed in on
            // the right by the send button, and three-on-top/one-below read as two rows of
            // unrelated things rather than one composer.
            // ⚠️ A UIKit text view, not `TextField`. SwiftUI's field drops any non-text flavour on
            // the pasteboard and offers no Paste for a copied image, and `onPasteCommand` — the
            // modifier that would intercept it — is macOS-only. Owning the responder is the only
            // way the system menu (Select / Select All / Paste / AutoFill) can accept an image.
            PastingTextView(
                text: text,
                placeholder: "Message…",
                onAttach: { providers in Task { await attach(providers: providers) } },
                onHeightChange: { fieldHeight = $0 }
            )
            // `maxWidth: .infinity` caps the representable at the row's width, so its intrinsic
            // width never drives the layout.
            .frame(maxWidth: .infinity)
            .frame(height: fieldHeight)
            .focused($focused)
            .accessibilityIdentifier("composer.field")

            controlRow
        }
        .padding(10)
        .glassPanel(cornerRadius: 26)
        // Inset from the edges so the panel floats over the transcript, which is what makes the
        // glass read as a layer rather than a docked bar.
        .padding(.horizontal, 10)
        // ⚠️ No bottom padding here. As a `safeAreaInset` the system already places this above the
        // home indicator and the keyboard; adding more stacked a second gap that grew with the
        // panel and read as the insets doubling on every new line.
        .padding(.bottom, 4)
        .photosPicker(isPresented: photoPickerBinding, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            handleFileImport(result)
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { image in Task { await attach(image: image) } }
                .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await attach(photo: item) }
        }
        .task(id: sessionID) {
            await refreshPermissionMode()
            await loadSlashCommands()
        }
        .accessibilityIdentifier("composer")
    }

    // MARK: - Rows

    @ViewBuilder
    private var controlRow: some View {
        HStack(spacing: 8) {
            attachmentMenu

            if let control = HarnessCapabilities.modelControl(for: mode) {
                modelPill(control)
            }

            if HarnessCapabilities.supportsPermissionCycling(mode) {
                permissionPill
            }

            Spacer(minLength: 0)

            sendButton
        }
    }


    /// True when the agent is mid-turn, so there is something to interrupt.
    private var isWorking: Bool { session?.effectiveStatus == .busy }

    /// ⚠️ Stop only when there is nothing to send. With text typed, the primary action is
    /// unambiguously "send that" — swapping it for a stop button would strand the message and make
    /// the button mean two different things depending on state the user cannot see.
    private var showsStop: Bool { isWorking && !canSend }

    private var sendButton: some View {
        Button {
            Task { showsStop ? await interrupt() : await send() }
        } label: {
            Group {
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: showsStop ? "stop.fill" : "arrow.up")
                        .font(.body.weight(.semibold))
                }
            }
            .frame(width: Self.controlHeight, height: Self.controlHeight)
        }
        .disabled((!canSend && !showsStop) || isSending || busyReason != nil)
        .composerSendStyle(enabled: (canSend || showsStop) && !isSending && busyReason == nil)
        .accessibilityIdentifier(showsStop ? "composer.stop" : "composer.send")
    }

    /// Interrupt the current turn.
    private func interrupt() async {
        guard let api = model.apiClient else { return }
        do {
            _ = try await api.sendInput(
                SessionInputRequest(input: SessionControl.interrupt),
                id: sessionID,
                scope: model.scope
            )
            model.transcriptFeeds[sessionID]?.refresh()
        } catch {
            model.report(error, title: "Could not interrupt")
        }
    }

    /// Staged attachments, shown as thumbnails the way a chat app does — rather than as a path
    /// pasted into the message, which read like a shell prompt.
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments(for: sessionID)) { item in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let preview = item.preview {
                                Image(uiImage: preview)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                            } else {
                                Image(systemName: "doc")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, height: 56)
                                    .background(Color(.tertiarySystemFill))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Button {
                            model.removeAttachment(item.id, for: sessionID)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .padding(3)
                        .accessibilityLabel("Remove \(item.fileName)")
                    }
                    .accessibilityIdentifier("composer.attachment")
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 62)
    }

    /// Commands matching what has been typed, or nil when the picker should not show.
    private var visibleSlashCommands: [SlashCommand]? {
        guard let query = SlashCommandTrigger.query(in: text.wrappedValue) else { return nil }
        guard !slashCommands.isEmpty else { return nil }
        let needle = query.lowercased()
        guard !needle.isEmpty else { return slashCommands }
        // Prefix matches first, so `/mo` surfaces `model` before `gortex-commit-model`.
        let prefix = slashCommands.filter { $0.name.lowercased().hasPrefix(needle) }
        let contains = slashCommands.filter {
            !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle)
        }
        return prefix + contains
    }

    // MARK: - Controls

    private var attachmentMenu: some View {
        Menu {
            // Camera first: it is the one option that cannot be reached any other way, and the
            // simulator/device split is handled by availability rather than by hiding it silently.
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Camera", systemImage: "camera") { showingCamera = true }
            }
            Button("Photos", systemImage: "photo.on.rectangle") { photoItem = nil; showPhotos = true }
            Button("Files", systemImage: "folder") { showingFiles = true }

            // ⚠️ iOS has no `onPasteCommand` — that modifier is macOS-only, and a TextField's own
            // paste silently drops anything that is not text. Reading the pasteboard explicitly is
            // the only way an image or file copied from another app can reach the composer.
            if pasteboardHasAttachment {
                Divider()
                Button("Paste", systemImage: "doc.on.clipboard") { Task { await pasteAttachment() } }
            }
        } label: {
            pillLabel(systemImage: "plus", text: nil)
        }
        .tint(.primary)
        .disabled(busyReason != nil)
        .accessibilityIdentifier("composer.attach")
    }

    @State private var showPhotos = false
    private var photoPickerBinding: Binding<Bool> {
        Binding(get: { showPhotos }, set: { showPhotos = $0 })
    }

    @ViewBuilder
    private func modelPill(_ control: HarnessCapabilities.ModelControl) -> some View {
        let current = session?.modelBadge ?? "Model"
        switch control {
        case .directCommand(let options):
            Menu {
                ForEach(options) { option in
                    Button(option.label) { Task { await switchModel(to: option) } }
                }
            } label: {
                pillLabel(systemImage: nil, text: current)
            }
            .tint(.primary)
            .accessibilityIdentifier("composer.model")

        case .readOnly:
            // Shown, not offered: these CLIs present `/model` as an interactive picker, so a menu
            // here would leave a half-open dialog in the pane.
            pillLabel(systemImage: nil, text: current)
                .accessibilityIdentifier("composer.model.readonly")
        }
    }

    private var permissionPill: some View {
        Button {
            Task { await cyclePermissionMode() }
        } label: {
            pillLabel(
                systemImage: permissionMode?.symbolName ?? "chevron.left.forwardslash.chevron.right",
                text: permissionMode?.label ?? "Mode"
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.permission")
    }

    /// Every control in the row is this tall, so nothing sits proud of its neighbours.
    ///
    /// ⚠️ Height comes from an explicit `frame`, NOT from padding. Padding around content of
    /// differing intrinsic heights (an SF Symbol vs a text label vs a symbol+label pair) produces
    /// different totals — which is why "Mode" was taller than "Model".
    private static let controlHeight: CGFloat = 40

    @ViewBuilder
    private func pillLabel(systemImage: String?, text: String?) -> some View {
        let isIconOnly = text == nil
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.subheadline.weight(.semibold))
            }
            if let text {
                Text(text).font(.subheadline).lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, isIconOnly ? 0 : 14)
        // An icon-only control is a circle; a labelled one is a capsule of the same height.
        .frame(width: isIconOnly ? Self.controlHeight : nil, height: Self.controlHeight)
        .composerPillStyle(circular: isIconOnly)
    }

    // MARK: - Actions

    /// An attachment alone is a valid message — the agent can act on a file with no words.
    private var canSend: Bool {
        !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.attachments(for: sessionID).isEmpty
    }

    private func send() async {
        guard let api = model.apiClient, canSend, !isSending else { return }
        // ⚠️ Paths are appended HERE, not when the file was picked. The agent opens the file by
        // path, so the message must carry it — but the composer shows a thumbnail until send, so
        // attaching a photo does not fill the field with a filesystem path.
        let staged = model.attachments(for: sessionID)
        let body = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = ([body] + staged.map(\.path))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        isSending = true
        defer { isSending = false }

        do {
            try await deliver(outgoing, api: api)
            text.wrappedValue = ""
            model.clearAttachments(for: sessionID)
            // Echo it immediately. The transcript is Claude Code's own log, so the real entry only
            // lands once the CLI writes it — and it queues the prompt outright when mid-turn.
            model.transcriptFeeds[sessionID]?.noteSent(outgoing)
        } catch {
            model.report(error, title: "Could not send")
        }
    }

    /// Type the message, then submit it as a SEPARATE, later keystroke.
    ///
    /// ⚠️ **Do not append `\r` to the text.** The server issues `send-keys Enter` immediately after
    /// `send-keys -l <text>`, and for anything but a short string that Enter reaches Claude Code's
    /// Ink composer before it has finished ingesting the text — the Enter is swallowed and the
    /// message sits in the composer unsent, while the request still reports success. Measured on a
    /// live pane: a 520-character payload ending in `\r` did not submit, the identical text
    /// followed by a lone `\r` did.
    ///
    /// The delay scales with length because the race is about how long Ink takes to consume the
    /// typed characters.
    private func deliver(_ message: String, api: any APIClientProtocol) async throws {
        // ⚠️ Newlines are STRIPPED by the input path, which would silently join a multi-paragraph
        // prompt into one run-on line. `send-key S-Enter` is the newline the composer understands,
        // so a multi-line message is typed line by line with real newlines between.
        let lines = message.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            if !line.isEmpty {
                _ = try await api.sendInput(SessionInputRequest(input: line), id: sessionID, scope: model.scope)
            }
            if index < lines.count - 1 {
                try await api.sendNewlineKey(id: sessionID, scope: model.scope)
            }
        }

        try await Task.sleep(for: submitDelay(for: message))
        _ = try await api.sendInput(SessionInputRequest(input: "\r"), id: sessionID, scope: model.scope)
    }

    /// How long to let Ink catch up before submitting.
    private func submitDelay(for message: String) -> Duration {
        // Floor covers the round trip; the per-character term covers Ink's ingest. Capped so a very
        // long paste does not feel stalled.
        let scaled = 150 + message.count
        return .milliseconds(min(scaled, 1500))
    }


    /// `/model <alias>` as a one-shot, for harnesses where that is known to work.
    private func switchModel(to option: HarnessCapabilities.ModelOption) async {
        guard let api = model.apiClient else { return }
        do {
            _ = try await api.sendInput(
                SessionInputRequest(input: "/model \(option.argument)\r"),
                id: sessionID,
                scope: model.scope
            )
            // The CLI reports the new model on its next status line; refreshing the list is what
            // updates the pill, rather than optimistically claiming the switch landed.
            await model.refreshSessions()
        } catch {
            model.report(error, title: "Could not switch the model")
        }
    }

    /// Cycle Claude's permission mode by sending the same bytes Shift+Tab produces.
    ///
    /// ⚠️ Falls back to the input endpoint when no terminal is attached, and that fallback is the
    /// whole feature working. `model.terminal(for:)` is a cache of panes the user has actually
    /// OPENED — in the chat view it is normally empty, so the old `guard … else { return }` made
    /// this button silently do nothing for anyone who had not visited the terminal tab first. The
    /// mode label still populated (it is read over HTTP), which made the control look alive.
    ///
    /// The bytes are identical either way: `POST /input` writes them with tmux `send-keys -l`, and
    /// since the payload carries no carriage return it never presses Enter.
    private func cyclePermissionMode() async {
        if let terminal = model.terminal(for: sessionID) {
            terminal.sendRaw(HarnessCapabilities.backTabSequence)
        } else if let api = model.apiClient {
            do {
                _ = try await api.sendInput(
                    SessionInputRequest(input: HarnessCapabilities.backTabSequence),
                    id: sessionID,
                    scope: model.scope
                )
            } catch {
                model.report(error, title: "Could not switch the permission mode")
                return
            }
        } else {
            return
        }
        // The footer redraws after the keypress; give it a beat, then read the mode back rather
        // than assuming which way the cycle went.
        try? await Task.sleep(for: .milliseconds(350))
        await refreshPermissionMode()
    }

    /// Fetch once per session. The command set is files on disk; it does not change mid-session
    /// often enough to justify polling.
    private func loadSlashCommands() async {
        guard slashCommands.isEmpty, let api = model.apiClient else { return }
        guard let response = try? await api.slashCommands(id: sessionID, scope: model.scope),
              response.available
        else { return }
        slashCommands = response.commands
    }

    /// Read the permission mode off the pane, since nothing else reports it.
    private func refreshPermissionMode() async {
        guard HarnessCapabilities.supportsPermissionCycling(mode), let api = model.apiClient else { return }
        guard let snapshot = try? await api.terminalSnapshot(id: sessionID, full: false, tailBytes: 8192, scope: model.scope)
        else { return }
        permissionMode = PermissionModeReader.parse(snapshot.terminalBuffer)
    }

    // MARK: - Attachments

    /// Items pasted or dropped into the field.
    private func attach(providers: [NSItemProvider]) async {
        for provider in providers {
            if provider.canLoadObject(ofClass: UIImage.self) {
                let image: UIImage? = await withCheckedContinuation { continuation in
                    provider.loadObject(ofClass: UIImage.self) { object, _ in
                        continuation.resume(returning: object as? UIImage)
                    }
                }
                if let image { await attach(image: image) }
                continue
            }
            // A copied file arrives as a URL; read it under a security scope like the importer.
            guard let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL
            else { continue }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            await upload(data: data, filename: url.lastPathComponent, mimeType: type)
        }
    }

    private func attach(photo item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        await upload(data: data, filename: "photo-\(stamp()).png", mimeType: "image/png")
    }

    private func attach(image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        await upload(data: data, filename: "camera-\(stamp()).jpg", mimeType: "image/jpeg")
    }

    private func handleFileImport(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else { return }
        Task {
            for url in urls {
                // Security-scoped: a file picked outside the sandbox is unreadable without this,
                // and the failure is a silent empty read rather than an error.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                await upload(data: data, filename: url.lastPathComponent, mimeType: type)
            }
        }
    }

    /// True when the pasteboard holds something the field itself cannot take.
    private var pasteboardHasAttachment: Bool {
        UIPasteboard.general.hasImages || UIPasteboard.general.hasURLs
    }

    private func pasteAttachment() async {
        let pasteboard = UIPasteboard.general
        if let image = pasteboard.image {
            await attach(image: image)
            return
        }
        // A copied file arrives as a URL; read it under a security scope like the importer does.
        guard let url = pasteboard.urls?.first, url.isFileURL else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        await upload(data: data, filename: url.lastPathComponent, mimeType: type)
    }

    /// Upload, then put the resulting path in the field.
    ///
    /// The agent reads the file from disk, so the path is what it needs — pasting bytes into a
    /// prompt would give it nothing it can open.
    private func upload(data: Data, filename: String, mimeType: String) async {
        guard let api = model.apiClient else { return }
        busyReason = "Attaching \(filename)"
        defer { busyReason = nil }
        do {
            let response = try await api.uploadImage(
                data,
                filename: filename,
                mimeType: mimeType,
                sessionID: sessionID,
                scope: model.scope
            )
            model.addAttachment(
                .init(path: response.path, fileName: filename, preview: UIImage(data: data)),
                for: sessionID
            )
            focused = true
        } catch {
            model.report(error, title: "Could not attach \(filename)")
        }
    }

    private func stamp() -> Int { Int(Date().timeIntervalSince1970) }
}

// MARK: - Camera

/// `UIImagePickerController` for a single camera shot.
///
/// Not `PhotosPicker`: that reads the library. The camera is a separate source and, on a device
/// without one, `isSourceTypeAvailable` keeps the menu entry from appearing at all.
struct CameraCapture: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraCapture
        init(_ parent: CameraCapture) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
