import PhotosUI
import SafariServices
import SwiftUI
import UniformTypeIdentifiers

/// One terminal pane: the Ghostty surface, a prompt composer, and the attachment flow.
struct TerminalPaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let sessionID: String
    let isPrimary: Bool

    /// Terminal focus is owned by UIKit's first responder, and the representable keeps this in
    /// step both ways. It is deliberately NOT `@FocusState`: SwiftUI's focus system has no native
    /// focusable view to anchor to here and resets itself on re-evaluation, which would tear the
    /// keyboard down the moment it opened.
    @State private var terminalFocused = false
    /// Bumped to ask the Ghostty surface to give up the keyboard; see `dismissKeyboard()`.
    @State private var terminalResignRequest = 0
    /// Imperative handle to the live terminal view — paste, and the long-press selection payload.
    @State private var surfaceProxy = TerminalSurfaceProxy()
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsFileImporter = false
    @State private var showsCamera = false
    @State private var showsPhotoPicker = false
    @State private var uploads: [AttachmentUpload] = []
    /// One sheet slot: SwiftUI honours only the FIRST `.sheet` modifier on a view and silently
    /// ignores the rest, so the attachment picker and the link viewer share this.
    @State private var presented: Presentation?

    private enum Presentation: Identifiable {
        case attachmentSources
        case link(URL)
        case sessionSettings
        case selection(TerminalSelectionPayload)

        var id: String {
            switch self {
            case .attachmentSources: "attach"
            case let .link(url): url.absoluteString
            case .sessionSettings: "settings"
            case let .selection(payload): "selection-\(payload.id)"
            }
        }
    }

    private var terminal: TerminalSession? { model.terminal(for: sessionID) }
    private var session: SessionSnapshot? { model.session(id: sessionID) }

    /// On compact widths the navigation bar already names the session and carries the way out, so
    /// a second identity row underneath it is redundant chrome on the smallest screen. On iPad the
    /// pane can be one of two side by side, and each needs its own header.
    private var showsHeader: Bool { horizontalSizeClass == .regular }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Divider()
            }
            // ⚠️ The terminal is only *hidden* when the transcript is showing, not torn down —
            // its socket is the input path and the pane's live output stream, so unmounting it
            // would make every switch back a reconnect plus a full scrollback re-pull.
            if model.viewMode(for: sessionID) == .transcript {
                SessionTranscriptView(sessionID: sessionID)
            } else {
                terminalSurface
            }
            if !uploads.isEmpty {
                UploadTray(uploads: $uploads, onRetry: retry)
                Divider()
            }
        }
        .background(Color(.systemBackground))
        // The composer's own keyboard is what pushes content up; the terminal is constrained to
        // the keyboard guide inside its representable, so no manual notification handling.
        //
        // ⚠️ The navigation bar is never hidden here. It used to be hidden whenever the terminal
        // or composer had focus, to avoid stacking two rows of controls — but the bar is also the
        // only way back out of a session, and the keyboard could not be dismissed either, so
        // tapping the terminal trapped the user in the pane with no exit.
        .task(id: sessionID) { model.ensureTerminal(for: sessionID) }
        .toolbar { keyboardDismissToolbarItem }
        .sheet(item: $presented) { destination in
            switch destination {
            case .attachmentSources:
                AttachmentSourceSheet(
                    onPickPhotos: { presented = nil; showsPhotoPicker = true },
                    onPickFiles: { presented = nil; showsFileImporter = true },
                    onCamera: { presented = nil; showsCamera = true },
                    onPaste: { presented = nil; pasteFromClipboard() }
                )
                .presentationDetents([.height(260)])
            case let .link(url):
                SafariView(url: url).ignoresSafeArea()
            case .sessionSettings:
                NavigationStack { SessionSettingsView(sessionID: sessionID) }
            case let .selection(payload):
                TerminalSelectionView(payload: payload)
            }
        }
        // Ghostty reports a tapped link on the session; hand it to the one sheet slot.
        .onChange(of: surfaceProxy.pendingSelection) { _, payload in
            guard let payload else { return }
            presented = .selection(payload)
            surfaceProxy.pendingSelection = nil
        }
        .onChange(of: terminal?.pendingLink) { _, link in
            guard let link else { return }
            presented = .link(link)
            terminal?.pendingLink = nil
        }
        .photosPicker(
            isPresented: $showsPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: 8,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            let captured = items
            photoItems = []
            Task { await ingest(photoItems: captured) }
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): Task { await ingest(fileURLs: urls) }
            case let .failure(error): model.report(error, title: "Could not read the file")
            }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraCaptureView { data in
                Task { await upload(data: data, filename: "camera-\(Int(Date.now.timeIntervalSince1970)).jpg", mime: "image/jpeg") }
            }
            .ignoresSafeArea()
        }
    }

    /// Whether the terminal is holding the on-screen keyboard.
    private var keyboardIsUp: Bool { terminalFocused }

    /// The only way to put the keyboard away.
    ///
    /// A hardware keyboard has Escape and a `UITextField` has a return key, but the Ghostty
    /// surface is a first responder with neither: once it took focus there was no gesture, key or
    /// control that gave it back, and the keyboard covered half the screen for the rest of the
    /// session. Offered on compact widths only when the keyboard is actually up — on iPad the
    /// pane header carries the same control, because two side-by-side panes cannot share one
    /// toolbar slot.
    @ToolbarContentBuilder
    private var keyboardDismissToolbarItem: some ToolbarContent {
        if horizontalSizeClass == .compact, keyboardIsUp {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: dismissKeyboard) {
                    Label("Hide Keyboard", systemImage: "keyboard.chevron.compact.down")
                }
                .accessibilityIdentifier("terminal.hideKeyboard")
            }
        }
        if horizontalSizeClass == .compact, isPrimary {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    viewModePicker
                    Divider()
                    terminalActions
                    Divider()
                    Button("Session Settings", systemImage: "slider.horizontal.3") {
                        presented = .sessionSettings
                    }
                    .accessibilityIdentifier("terminal.sessionSettings")
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("terminal.actions")
            }
        }
    }

    /// Terminal-vs-transcript, inline in the actions menu.
    ///
    /// Also in Session Settings, and deliberately in both: settings is where you set a default,
    /// but flipping between the live pane and the readable one is something you do mid-task, and
    /// making that a two-screen trip would stop people using it.
    @ViewBuilder
    private var viewModePicker: some View {
        Picker("View", selection: Binding(
            get: { model.viewMode(for: sessionID) },
            set: { model.setViewMode($0, for: sessionID) }
        )) {
            ForEach(SessionViewMode.allCases) { mode in
                Label(mode.title, systemImage: mode.symbolName).tag(mode)
            }
        }
        .pickerStyle(.inline)
        .accessibilityIdentifier("terminal.viewMode")
    }

    /// Paste, select and attach — the actions that used to live only on the composer row or in a
    /// menu the terminal could not raise.
    @ViewBuilder
    private var terminalActions: some View {
        Button("Paste", systemImage: "doc.on.clipboard") { surfaceProxy.paste() }
            .disabled(!surfaceProxy.canPaste)
            .accessibilityIdentifier("terminal.paste")

        Button("Select Text", systemImage: "selection.pin.in.out") {
            guard let text = surfaceProxy.viewportText(), !text.isEmpty else { return }
            presented = .selection(TerminalSelectionPayload(text: text, anchorRange: nil))
        }
        .accessibilityIdentifier("terminal.selectText")

        Button("Attach Image", systemImage: "paperclip") { presented = .attachmentSources }
            .accessibilityIdentifier("terminal.attach")
    }

    private func dismissKeyboard() {
        // Clear the intent as well as issuing the resign. The delegate reports focus back
        // asynchronously, so leaving this `true` lets the next update re-acquire the keyboard
        // before the change has been observed.
        terminalFocused = false
        // The terminal's first responder is UIKit's, not SwiftUI's: the representable resigns it
        // on the next update when this counter changes.
        terminalResignRequest += 1
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if let session {
                StatusDot(
                    session: session,
                    needsAttention: model.needsAttention.contains(sessionID),
                    waiting: model.waitingForInput.contains(sessionID)
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let dir = session.workingDir {
                        Text(dir)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            } else {
                Text("Session unavailable").font(.subheadline).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let terminal {
                PaneStateChip(state: terminal.state, columns: terminal.columns, rows: terminal.rows)
            }

            Menu {
                viewModePicker
                Divider()
                terminalActions
                Divider()
                Button("Session Settings", systemImage: "slider.horizontal.3") {
                    presented = .sessionSettings
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Terminal Actions")
            .accessibilityIdentifier("terminal.actions.\(sessionID)")

            if keyboardIsUp {
                Button(action: dismissKeyboard) {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide Keyboard")
                .accessibilityIdentifier("terminal.hideKeyboard.\(sessionID)")
            }

            if !isPrimary {
                Button {
                    model.secondarySessionID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close second pane")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Surface

    @ViewBuilder
    private var terminalSurface: some View {
        if let terminal {
            ZStack {
                GhosttyTerminalView(
                    session: terminal,
                    controller: model.terminalController,
                    fontSize: Float(model.preferences.terminalFontSize),
                    accessoryItems: model.preferences.accessoryItems,
                    isFocused: $terminalFocused,
                    resignRequest: terminalResignRequest,
                    proxy: surfaceProxy
                )

                switch terminal.state {
                case .loadingSnapshot:
                    ProgressView("Loading scrollback…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                case let .failed(message):
                    TerminalOverlayMessage(symbol: "exclamationmark.triangle", title: "Terminal unavailable", message: message) {
                        terminal.stop(); terminal.start()
                    }
                case let .ended(reason):
                    TerminalOverlayMessage(symbol: "stop.circle", title: "Session ended", message: reason, actionTitle: "Restart") {
                        Task { await restartSession() }
                    }
                case .idle, .live, .reconnecting:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // ⚠️ **No SwiftUI tap gesture here.** `UITerminalView` installs its own tap, drag and
            // long-press recognizers: tap focuses and positions, drag selects, long-press raises
            // the Copy menu, and a tap on a URL opens it. A `.onTapGesture` on this container wins
            // over all of them, which is why typing needed the composer, why text could not be
            // selected or copied, and why links did nothing. Focus is reported back through the
            // delegate, so the binding still tracks reality.
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func restartSession() async {
        guard let api = model.apiClient, let session else { return }
        do {
            if session.mode == .shell {
                try await api.startShell(id: sessionID, scope: model.scope)
            } else {
                // Only an explicit user-initiated restart clears a tripped PTY-exit breaker. This
                // *is* that gesture, so the flag is deliberately true here and nowhere else.
                try await api.startInteractive(id: sessionID, clearBreaker: true, scope: model.scope)
            }
            model.terminal(for: sessionID)?.stop()
            model.terminal(for: sessionID)?.start()
            await model.refreshSessions()
        } catch {
            model.report(error, title: "Could not restart")
        }
    }

    // MARK: - Attachments

    private func pasteFromClipboard() {
        guard let image = UIPasteboard.general.image,
              let data = image.jpegData(compressionQuality: 0.9)
        else {
            model.report(AttachmentError.noClipboardImage, title: "Nothing to paste")
            return
        }
        Task { await upload(data: data, filename: "paste-\(Int(Date.now.timeIntervalSince1970)).jpg", mime: "image/jpeg") }
    }

    private func ingest(photoItems items: [PhotosPickerItem]) async {
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let (name, mime) = Self.describe(data: data, suggested: item.itemIdentifier)
                await upload(data: data, filename: name, mime: mime)
            } catch {
                model.report(error, title: "Could not read the photo")
            }
        }
    }

    private func ingest(fileURLs urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                await upload(data: data, filename: url.lastPathComponent, mime: mime)
            } catch {
                model.report(error, title: "Could not read the file")
            }
        }
    }

    /// Names the payload from its **bytes**, not from a picker-supplied extension.
    ///
    /// The server sniffs magic bytes and rejects a mismatch with `415`; a HEIC that a gallery
    /// mislabels as JPEG is detected and converted server-side, so the honest thing is to send
    /// the real type we can see and let the server do the rest.
    static func describe(data: Data, suggested: String?) -> (String, String) {
        let stamp = Int(Date.now.timeIntervalSince1970)
        let base = suggested.map { String($0.prefix(24)).replacingOccurrences(of: "/", with: "-") } ?? "image-\(stamp)"

        if data.count >= 12 {
            let bytes = [UInt8](data.prefix(12))
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("\(base).png", "image/png") }
            if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return ("\(base).jpg", "image/jpeg") }
            if bytes.starts(with: [0x47, 0x49, 0x46]) { return ("\(base).gif", "image/gif") }
            if bytes.starts(with: [0x42, 0x4D]) { return ("\(base).bmp", "image/bmp") }
            // RIFF....WEBP
            if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
                return ("\(base).webp", "image/webp")
            }
            // ....ftypheic / ftypheif / ftypmif1
            if Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
                return ("\(base).heic", "image/heic")
            }
        }
        return ("\(base).png", "image/png")
    }

    private func upload(data: Data, filename: String, mime: String) async {
        let upload = AttachmentUpload(filename: filename, byteCount: data.count)
        uploads.append(upload)
        await performUpload(id: upload.id, data: data, filename: filename, mime: mime)
    }

    private func retry(_ upload: AttachmentUpload) {
        guard let payload = upload.payload else { return }
        Task { await performUpload(id: upload.id, data: payload.data, filename: payload.filename, mime: payload.mime) }
    }

    private func performUpload(id: UUID, data: Data, filename: String, mime: String) async {
        guard let api = model.apiClient else { return }
        setUpload(id: id, state: .uploading, payload: .init(data: data, filename: filename, mime: mime))
        do {
            let response = try await api.uploadImage(data, filename: filename, mimeType: mime,
                                                     sessionID: sessionID, scope: model.scope)
            setUpload(id: id, state: .finished(path: response.path), payload: nil)
            // Type the saved path at the cursor rather than sending it. The agent needs the path
            // as part of a prompt, and nothing in this app submits on the user's behalf — there is
            // no Enter here, so the user finishes the sentence and presses return themselves.
            model.terminal(for: sessionID)?.sendRaw(response.path + " ")
        } catch {
            let message = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            setUpload(id: id, state: .failed(message), payload: .init(data: data, filename: filename, mime: mime))
        }
    }

    private func setUpload(id: UUID, state: AttachmentUpload.State, payload: AttachmentUpload.Payload?) {
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
        uploads[index].state = state
        if let payload { uploads[index].payload = payload }
    }
}

// MARK: - Supporting views

private struct PaneStateChip: View {
    let state: TerminalPaneState
    let columns: Int
    let rows: Int

    var body: some View {
        switch state {
        case .live:
            Text("\(columns)×\(rows)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .accessibilityLabel("\(columns) columns by \(rows) rows")
        case .loadingSnapshot:
            ProgressView().controlSize(.mini)
        case let .reconnecting(attempt):
            Label(attempt <= 1 ? "Reconnecting" : "Reconnecting \(attempt)", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
        case .ended:
            Label("Ended", systemImage: "stop.circle").font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Label("Error", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }
}

private struct TerminalOverlayMessage: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String = "Retry"
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct SafariLink: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Links are opened in `SFSafariViewController`, out of process, never in a `WKWebView`.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

enum AttachmentError: LocalizedError {
    case noClipboardImage

    var errorDescription: String? {
        switch self {
        case .noClipboardImage: "The clipboard does not contain an image."
        }
    }
}
