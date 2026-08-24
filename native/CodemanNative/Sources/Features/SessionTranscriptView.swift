import SwiftUI
import UIKit

/// The session's conversation as a native document, as an alternative to the Ghostty grid.
///
/// The terminal shows what the agent *painted*; this shows what it *did* — prose as text, tool
/// calls as collapsible rows, edits as diffs. That makes it readable on a phone at a sane font
/// size, selectable and copyable per element, and immune to the reflow damage a resized tmux pane
/// bakes into its scrollback.
///
/// ⚠️ Claude-mode only, and it says so rather than looking broken: the other CLIs render their own
/// TUIs and write no Claude transcript, so `availability` carries the server's reason and the
/// empty state points the user back to the terminal.
struct SessionTranscriptView: View {
    @Environment(AppModel.self) private var model

    let sessionID: String

    @State private var feed: TranscriptFeed?
    /// Distance from the bottom, in points, straight from the scroll view's own geometry.
    ///
    /// ⚠️ Replaces a drag heuristic that only ever set "the user scrolled away" and never cleared
    /// it — which is why the jump button showed permanently, including when already at the bottom.
    /// Geometry is the only thing that actually knows where the viewport is.
    @State private var distanceFromBottom: CGFloat = 0

    /// Within a screenful of the end: close enough to keep following new output.
    private var isNearBottom: Bool { distanceFromBottom < Self.nearBottomSlack }

    private static let nearBottomSlack: CGFloat = 120

    /// The two geometry values the view reacts to, read in one pass.
    private struct ScrollMetrics: Equatable {
        var distanceFromBottom: CGFloat
        var bottomInset: CGFloat
    }

    /// ⚠️ Drives scrolling by EDGE, not by row id. `ScrollViewProxy.scrollTo(id:)` is a silent
    /// no-op when the target row has not been realised by the `LazyVStack` — which is exactly the
    /// case when the user is far up a long conversation and taps "jump to latest". Targeting the
    /// bottom edge needs no row to exist.

    /// The CLI's own status line while a turn is running.
    @State private var workingStatus: WorkingStatusReader.Status?

    /// The agent is mid-turn.
    private var isWorking: Bool { model.session(id: sessionID)?.effectiveStatus == .busy }

    /// Whether the opening scroll-to-bottom has run, so it happens once rather than on every
    /// content change (which would fight the reader scrolling up).
    @State private var hasSettledAtBottom = false
    /// False until the opening layout has been parked at the newest message.
    ///
    /// ⚠️ Gates the top-of-list auto-paging. A `LazyVStack` realises its LEADING rows during the
    /// first layout pass, so the "load earlier" sentinel's `onAppear` fired the instant a chat
    /// opened — which cleared `followsTail` and re-anchored the viewport to the top of the page it
    /// had just fetched. That is why opening a chat did not land at the end, and why the jump
    /// button was already showing before the reader had touched anything.
    @State private var hasSettled = false

    var body: some View {
        Group {
            if let feed {
                content(feed)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // ⚠️ `safeAreaInset`, not a VStack. Stacking the composer below the scroll view gave it its
        // own strip and content stopped dead above it; as a safe-area inset the transcript extends
        // BEHIND the glass and the scroll view gets matching content insets for free — which is
        // also what keeps the last message reachable when the keyboard is up, since the keyboard
        // grows the same safe area.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Only where sending makes sense: a session with no transcript has nothing to reply
            // into, and the empty state already points at the terminal.
            if feed?.availability != .unsupported {
                TranscriptComposer(sessionID: sessionID)
            }
        }
        .background(Color(.systemGroupedBackground))
        // Links in agent prose open in-app rather than switching to Safari and losing the
        // reader's place. Applied here because this view presents no sheet of its own.
        .inAppBrowser()
        .onAppear {
            let created = model.ensureTranscriptFeed(for: sessionID)
            feed = created
            created?.start()
        }
        .onDisappear { feed?.stop() }
        // ⚠️ Polled only while working, and separately from the transcript. The status line lives
        // in the PANE, not the JSONL — Claude writes no transcript entry for "still thinking" — so
        // it can only come from a terminal capture, and capturing on every transcript poll would
        // double the request rate for a session that is sitting idle.
        .task(id: isWorking) {
            guard isWorking else {
                workingStatus = nil
                return
            }
            while !Task.isCancelled, isWorking {
                if let api = model.apiClient,
                   let snapshot = try? await api.terminalSnapshot(
                       id: sessionID, full: false, tailBytes: 4096, scope: model.scope
                   ) {
                    workingStatus = WorkingStatusReader.parse(snapshot.terminalBuffer)
                }
                try? await Task.sleep(for: .milliseconds(1200))
            }
            workingStatus = nil
        }
    }

    @ViewBuilder
    private func content(_ feed: TranscriptFeed) -> some View {
        // ⚠️ Order matters, and "nothing yet" is LAST for a reason. It is the only branch that
        // asserts the conversation is empty, and it must never stand in for a request that failed
        // or a server that cannot answer — an old Codeman with no transcript route reported a long
        // conversation as "Send a prompt and the conversation appears here."
        if feed.availability == .unsupported {
            ContentUnavailableView {
                Label("Transcript not supported", systemImage: "arrow.up.circle")
            } description: {
                Text("This Codeman server is older than the transcript view. Update the server to enable it — the terminal works either way.")
            } actions: {
                Button("Show Terminal") { model.setViewMode(.terminal, for: sessionID) }
                    .buttonStyle(.glassAction)
            }
        } else if case .unavailable(let reason) = feed.availability, feed.blocks.isEmpty {
            ContentUnavailableView {
                Label("No transcript", systemImage: "text.bubble")
            } description: {
                Text(reason)
            } actions: {
                Button("Show Terminal") { model.setViewMode(.terminal, for: sessionID) }
                    .buttonStyle(.glassAction)
            }
        } else if feed.blocks.isEmpty, feed.isLoading {
            ProgressView("Loading conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if feed.blocks.isEmpty, let error = feed.loadError {
            ContentUnavailableView {
                Label("Couldn't load the conversation", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { feed.refresh() }
                    .buttonStyle(.glassAction)
                Button("Show Terminal") { model.setViewMode(.terminal, for: sessionID) }
            }
        } else if feed.blocks.isEmpty, feed.availability == .unknown {
            // No answer has arrived yet and nothing failed — still waiting, not empty.
            ProgressView("Loading conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if feed.blocks.isEmpty {
            ContentUnavailableView(
                "Nothing yet",
                systemImage: "text.bubble",
                description: Text("Send a prompt and the conversation appears here.")
            )
        } else {
            transcript(feed)
        }
    }

    private func transcript(_ feed: TranscriptFeed) -> some View {
        ScrollViewReader { proxy in
            // ⚠️ A ZStack, so the button is a SIBLING of the scroll view rather than its overlay.
            // As an overlay it passed `isHittable` and the tap synthesized, but the action never
            // ran — a `Button` layered onto a `ScrollView` sits inside that scroll view's gesture
            // territory, and the pan recognizer claims the touch. Hittability and gesture
            // ownership are different questions, which is why the geometry looked fine every time.
            ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    // Top-of-list affordance. `onAppear` on a sentinel is how a LazyVStack learns
                    // the reader has scrolled to the top; the explicit button is the fallback for
                    // when the sentinel never appears (a short page that never scrolls).
                    if feed.canLoadOlder {
                        HStack {
                            Spacer()
                            if feed.isLoadingOlder {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Load earlier messages") { loadOlder(proxy) }
                                    .font(.caption)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        // Gated on `hasSettled` — see there. Until the opening scroll has run this
                        // row is realised but nowhere near the screen, and paging off it threw the
                        // reader to the top. The explicit button above stays live either way, which
                        // is what covers a first page too short to ever scroll.
                        .onAppear {
                            guard hasSettled else { return }
                            loadOlder(proxy)
                        }
                        .accessibilityIdentifier("transcript.loadOlder")
                    } else if feed.truncated {
                        Text("Beginning of the loaded history")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 2)
                    }

                    // ⚠️ Renders the GROUPED timeline, not the raw block list. A turn runs a
                    // dozen tools between two sentences; one card each buries the prose the
                    // reader actually wants. See `TranscriptTimeline`.
                    ForEach(TranscriptTimeline.build(feed.blocks)) { item in
                        switch item {
                        case .block(let block):
                            TranscriptBlockView(block: block, sessionID: sessionID).id(item.id)
                        case .steps(let group):
                            ToolStepRow(group: group, sessionID: sessionID).id(item.id)
                        }
                    }

                    if isWorking {
                        WorkingIndicatorView(status: workingStatus)
                            .padding(.top, 2)
                            .id(Self.workingRowID)
                    }

                    // ⚠️ NOT a 1pt spacer. `scrollTo` can only reach a child the LazyVStack has
                    // actually realised, and a zero-height clear view near the bottom often is
                    // not — which is why both the initial scroll and the jump button silently did
                    // nothing. A real, measurable footer is reachable.
                    Color.clear
                        .frame(height: 8)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
                // ⚠️ On the CONTENT, not on the outer container. `accessibilityIdentifier`
                // propagates to descendants, so identifying the whole view overwrote the
                // jump button's own id inside the overlay — it rendered and worked, but was
                // unaddressable, which is indistinguishable from "missing" in a UI test.
                .accessibilityIdentifier("transcript.\(sessionID)")
            }
            // ⚠️ NO `.scrollPosition(_:)` here, and adding one back will break scrolling outright.
            // A bound `ScrollPosition` is re-asserted on every body evaluation, and this view
            // re-evaluates constantly because the geometry observer below writes state on each
            // frame — so the binding reverted every drag and the list became unscrollable. That is
            // the real defect behind three rounds of "the jump button does nothing": measured with
            // screenshots, three fast swipes moved the content by zero pixels, and the button was
            // appearing only because `contentSize.height` grows as LazyVStack rows realise, which
            // inflates the distance-from-bottom while the view sits pinned. The scroll view owns
            // its own position; imperative jumps go through the proxy.
            // ⚠️ `.immediately`, not `.interactively`. An interactive dismiss ties the keyboard's
            // position to the drag, and this view ALSO re-pins the bottom whenever the safe-area
            // inset changes — so the two drive the inset against each other and the gesture stalls
            // partway, leaving a gap between the composer and a half-dismissed keyboard. Dismissing
            // outright on the first downward drag has one owner and always completes.
            .scrollDismissesKeyboard(.immediately)
            // ⚠️ `.initialOffset` ONLY. A plain `.defaultScrollAnchor(.bottom)` also re-anchors on
            // every content/inset size change, so each time the composer grew a line the list
            // jumped — the "insets doubled" effect. Restricting it to the initial offset keeps
            // "opens at the newest message" without re-pinning afterwards.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // ⚠️ ONE observer, two jobs. `onScrollGeometryChange` does not stack: applying it
            // twice to the same view keeps only one, so a second copy silently disabled the
            // distance tracking and the jump button stopped working. Both values are therefore
            // read in a single pass.
            //
            // ⚠️ `visibleRect`, not offset/inset arithmetic. Deriving the distance from
            // `contentOffset + containerSize` has to account for both content insets, and with a
            // `safeAreaInset` composer plus a nav bar the sign is easy to get wrong — an earlier
            // attempt reported a large distance while sitting at the bottom, so the button showed
            // permanently. `visibleRect` is already inset-corrected.
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    distanceFromBottom: max(0, geometry.contentSize.height - geometry.visibleRect.maxY),
                    bottomInset: geometry.contentInsets.bottom
                )
            } action: { old, new in
                distanceFromBottom = new.distanceFromBottom
                // The keyboard grows the bottom safe area, shrinking the viewport; the content
                // does not move with it, so the last message would slide underneath. Re-pin only
                // when already at the bottom, so a reader scrolled up into history is never yanked.
                // ⚠️ Only when the keyboard is APPEARING (inset grew). Re-pinning as it retracts
                // fights the dismissal animation, which is the other half of the stuck-keyboard
                // bug — on the way out the content already has room and needs no help.
                if new.bottomInset > old.bottomInset, old.distanceFromBottom < Self.nearBottomSlack {
                    scrollToBottom(proxy, animated: false)
                }
            }
            .refreshable { feed.refresh() }
            .onChange(of: feed.lastBlockID) { _, _ in
                // Follow new output only while the reader is already at the end; scrolling up to
                // read history must not be yanked away by an arriving block.
                guard isNearBottom else { return }
                scrollToBottom(proxy, animated: true)
            }
            // ⚠️ Confirms the opening position, then arms the top sentinel. `defaultScrollAnchor`
            // places the FIRST layout, but the rows re-measure straight after it — markdown
            // reflows and images resize as they resolve — which leaves the viewport short of the
            // end. The belt-and-braces that used to sit here watched `feed.blocks.isEmpty`, which
            // is dead inside this view: the ScrollView is only built once blocks are non-empty, so
            // `wasEmpty` was never true and nothing ever ran.
            .task(id: sessionID) {
                hasSettled = false
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                scrollToBottom(proxy, animated: false)
                hasSettled = true
            }
            .overlay(alignment: .top) {
                if let error = feed.loadError {
                    Text(error)
                        .font(.caption2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 6)
                }
            }

            if !isNearBottom {
                ScrollToBottomButton { scrollToBottom(proxy, animated: true) }
                    .padding(.bottom, 12)
                    // ⚠️ Both are load-bearing. Conditionally-inserted ZStack content does not
                    // reliably keep the top of the z-order across re-renders, so without the
                    // explicit index the touch fell THROUGH to whatever transcript row happened to
                    // sit under the button — measured: tapping it opened a tool-step sheet instead
                    // of scrolling. `isHittable` cannot catch that, because the button really is on
                    // top geometrically; it just was not winning the gesture.
                    .zIndex(1)
                    .contentShape(Circle())
            }
            }
            // Drives the button's scale transition on BOTH edges; without animating the value
            // change it would appear and vanish instantly regardless of the transition.
            .animation(.snappy(duration: 0.25), value: isNearBottom)
        }
    }

    /// Scroll to the newest content.
    ///
    /// Targets the dedicated footer rather than the last block: the list renders
    /// `TranscriptTimeline.build(...)`, which folds a run of consecutive tool calls into ONE row
    /// keyed by its FIRST step, so `blocks.last!.id` is frequently not a rendered id at all and
    /// `scrollTo` on an id the list does not contain fails silently.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        // `Self.bottomAnchor` is a REAL 8pt footer rather than a zero-height spacer precisely so
        // the proxy has something to resolve — `scrollTo` is a silent no-op on an id the layout
        // cannot find.
        if animated {
            withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    /// Fetch the page above and keep the reader where they were.
    ///
    /// ⚠️ Prepending rows to a `LazyVStack` shifts everything below them down, so without
    /// re-anchoring, loading history yanks the viewport to a different part of the conversation.
    /// Pinning the previously-first block to the top is what makes it feel like scrolling.
    private func loadOlder(_ proxy: ScrollViewProxy) {
        guard let feed, feed.canLoadOlder, !feed.isLoadingOlder else { return }
        Task {
            guard let anchor = await feed.loadOlder() else { return }
            await MainActor.run {
                // No animation: an animated re-anchor reads as the list lurching.
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    private static let bottomAnchor = "transcript.bottom"
    private static let workingRowID = "transcript.working.row"
}

// MARK: - Block dispatch

struct TranscriptBlockView: View {
    let block: TranscriptBlock
    let sessionID: String

    var body: some View {
        switch block {
        case .user(let b): UserBubbleView(block: b, sessionID: sessionID)
        case .assistant(let b): AssistantBlockView(block: b, sessionID: sessionID)
        case .thinking(let b): ThinkingBlockView(block: b)
        // Tool calls and edits never render inline any more — they are folded into a
        // `ToolStepRow` by `TranscriptTimeline` and opened from its sheet. Reaching here would
        // mean the grouping missed a case, so show the compact row rather than nothing.
        case .toolCall, .diff:
            ToolStepRow(
                group: TranscriptTimeline.StepGroup(
                    id: block.id,
                    steps: [block],
                    summary: TranscriptTimeline.summarize([block]),
                    addedLines: 0,
                    removedLines: 0,
                    isRunning: false
                ),
                sessionID: sessionID
            )
        }
    }
}

// MARK: - User

private struct UserBubbleView: View {
    let block: TranscriptBlock.UserBlock
    let sessionID: String

    @Environment(AppModel.self) private var appModel

    /// Local echo: sent, but not yet written to the transcript by the CLI.
    private var isPending: Bool { block.id.hasPrefix("pending:") }

    /// The agent is mid-turn, so a delivered prompt is queued behind it.
    private var isWorking: Bool { appModel.session(id: sessionID)?.effectiveStatus == .busy }

    private var pendingLabel: String { isWorking ? "Queued" : "Sending…" }

    @State private var zoomed: UIImage?

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 6) {
                if let prose = AttachedImagePaths.strippingPaths(from: block.text) {
                    Text(prose)
                        .font(.body)
                        .textSelection(.enabled)
                        // ⚠️ Required because of the image strip below. A horizontal ScrollView
                        // advertises a large ideal width, the HStack hands this Text less than it
                        // asked for, and Text truncates rather than wrapping — the message ended
                        // mid-word with an ellipsis while the full string was present.
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Images the transcript itself carries (what Claude recorded), plus pictures the
                // user attached — those arrive as a PATH in the text, because Codeman types into a
                // terminal and a path is what the agent can open. Rendering the path as a picture
                // is what makes an attachment look attached rather than pasted.
                let attachedPaths = AttachedImagePaths.matches(in: block.text)
                if !block.images.isEmpty || !attachedPaths.isEmpty {
                    // A horizontal strip, not a stacked list: several screenshots in one message
                    // otherwise push the conversation off the screen for the length of a scroll.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(block.images) { ref in
                                TranscriptImageView(sessionID: sessionID, reference: ref) { zoomed = $0 }
                            }
                            ForEach(attachedPaths) { match in
                                AttachedImageView(sessionID: sessionID, path: match.path) { zoomed = $0 }
                            }
                        }
                    }
                }
                if block.truncated { TruncationNote() }

                if isPending {
                    // ⚠️ "Queued", not "Sending", once the agent is working. Delivery already
                    // succeeded — the POST returned — so the message is sitting in Claude Code's
                    // queue waiting for the current turn to end. Calling that "sending" reads as a
                    // failure when nothing has failed.
                    Label(pendingLabel, systemImage: isWorking ? "clock.badge.checkmark" : "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(isPending ? 0.65 : 1)
        }
        .accessibilityIdentifier("transcript.user")
        .transcriptMessageMenu(
            // A local echo is controllable — it has not run yet, whether it is queued behind a
            // turn or still landing. Anything already in the transcript has run and can only be
            // copied.
            state: isPending ? .queued : .settled,
            text: block.text,
            sessionID: sessionID,
            onDismiss: { appModel.transcriptFeeds[sessionID]?.dropPending(id: block.id) }
        )
        .sheet(item: Binding(get: { zoomed.map(ZoomedUserImage.init) }, set: { zoomed = $0?.image })) { item in
            TranscriptImageViewer(image: item.image)
        }
    }

    private struct ZoomedUserImage: Identifiable {
        let image: UIImage
        var id: String { "\(image.hashValue)" }
    }
}

// MARK: - Assistant

private struct AssistantBlockView: View {
    let block: TranscriptBlock.AssistantBlock
    let sessionID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A limit notice or tool failure arrives as ordinary assistant text; styling it as a
            // callout is what keeps it from being read past.
            if let notice = NoticeStyle.classify(block.text) {
                NoticeBlockView(style: notice, text: block.text)
            } else {
                MarkdownText(text: block.text)
            }
            if block.truncated { TruncationNote() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("transcript.assistant")
        .transcriptMessageMenu(state: .settled, text: block.text, sessionID: sessionID)
    }
}

// MARK: - Thinking

/// Extended reasoning, in a subtle material pill that stays collapsed once the thought is over.
///
/// Collapsed by default because reasoning is context, not the answer — it should be reachable
/// without pushing the actual response off the screen. The server drops reasoning blocks that
/// carry no plaintext, so this never renders an empty pill.
struct ThinkingBlockView: View {
    let block: TranscriptBlock.ThinkingBlock

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Thought for a moment")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(block.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                if block.truncated { TruncationNote().padding(.top, 4) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("transcript.thinking")
    }
}

// MARK: - Shared

/// Says a value was cut rather than letting the user assume they are reading all of it.
private struct TruncationNote: View {
    var body: some View {
        Label("Truncated", systemImage: "scissors")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
