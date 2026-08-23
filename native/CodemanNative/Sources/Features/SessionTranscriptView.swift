import SwiftUI

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
    /// Cleared once the user scrolls, so a jump to the bottom never fights a deliberate scroll up.
    @State private var followsTail = true

    var body: some View {
        Group {
            if let feed {
                content(feed)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            let created = model.ensureTranscriptFeed(for: sessionID)
            feed = created
            created?.start()
        }
        .onDisappear { feed?.stop() }
        .accessibilityIdentifier("transcript.\(sessionID)")
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
                    .buttonStyle(.borderedProminent)
            }
        } else if case .unavailable(let reason) = feed.availability, feed.blocks.isEmpty {
            ContentUnavailableView {
                Label("No transcript", systemImage: "text.bubble")
            } description: {
                Text(reason)
            } actions: {
                Button("Show Terminal") { model.setViewMode(.terminal, for: sessionID) }
                    .buttonStyle(.borderedProminent)
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
                    .buttonStyle(.borderedProminent)
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if feed.truncated {
                        Text("Showing the most recent \(feed.blocks.count) of \(feed.totalBlocks) entries")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 2)
                    }

                    ForEach(feed.blocks) { block in
                        TranscriptBlockView(block: block)
                            .id(block.id)
                    }

                    // Anchor for scroll-to-bottom: targeting the last block scrolls its TOP into
                    // view, which leaves a long final message hanging off the bottom of the screen.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { feed.refresh() }
            .onChange(of: feed.lastBlockID) { _, _ in
                guard followsTail else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            .overlay(alignment: .bottomTrailing) {
                if !followsTail {
                    Button {
                        followsTail = true
                        withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.callout.weight(.semibold))
                            .padding(10)
                            .background(.thinMaterial, in: Circle())
                    }
                    .padding(16)
                    .accessibilityLabel("Jump to latest")
                }
            }
            .simultaneousGesture(
                // Any upward drag hands control to the user. Re-arming happens through the
                // explicit jump button, never silently, so reading history is never yanked away.
                DragGesture().onChanged { value in
                    if value.translation.height > 12 { followsTail = false }
                }
            )
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
        }
    }

    private static let bottomAnchor = "transcript.bottom"
}

// MARK: - Block dispatch

struct TranscriptBlockView: View {
    let block: TranscriptBlock

    var body: some View {
        switch block {
        case .user(let b): UserBubbleView(block: b)
        case .assistant(let b): AssistantBlockView(block: b)
        case .thinking(let b): ThinkingBlockView(block: b)
        case .toolCall(let b): ToolCallView(block: b)
        case .diff(let b): DiffBlockView(block: b)
        }
    }
}

// MARK: - User

private struct UserBubbleView: View {
    let block: TranscriptBlock.UserBlock

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 6) {
                if !block.text.isEmpty {
                    Text(block.text)
                        .font(.body)
                        .textSelection(.enabled)
                }
                if block.imageCount > 0 {
                    Label(
                        block.imageCount == 1 ? "1 image" : "\(block.imageCount) images",
                        systemImage: "photo"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if block.truncated { TruncationNote() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityIdentifier("transcript.user")
    }
}

// MARK: - Assistant

private struct AssistantBlockView: View {
    let block: TranscriptBlock.AssistantBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownText(text: block.text)
            if block.truncated { TruncationNote() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("transcript.assistant")
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

// MARK: - Tool call

/// A tool execution as a compact accordion: name and one-line gist collapsed, full input and
/// output expanded.
///
/// Collapsed by default and deliberately so — a real turn runs dozens of tools, and expanding them
/// all would bury the conversation under command output. A failure is the exception: it is tinted
/// red so it is findable without opening every row.
struct ToolCallView: View {
    let block: TranscriptBlock.ToolCallBlock

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let input = block.input, !input.isEmpty {
                    labelled("Input") {
                        CodeBlockView(code: input, language: nil)
                        if block.inputTruncated { TruncationNote() }
                    }
                }
                if let result = block.result, !result.isEmpty {
                    labelled(block.isError ? "Error" : "Output") {
                        CodeBlockView(code: result, language: nil)
                        if block.resultTruncated {
                            Text(resultTruncationNote)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if block.isRunning {
                    Label("Still running", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(block.isError ? .red : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(block.isError ? .red : .primary)
                    if let summary = block.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)

                if block.isRunning {
                    ProgressView().controlSize(.mini)
                }
            }
            // ⚠️ The identifier goes on the LABEL, not on the DisclosureGroup. Applied to the
            // group it propagates to every descendant, so the expanded content's own identifiers
            // (the code blocks' Copy buttons) are overwritten with this one and become
            // unaddressable — verified in the accessibility tree.
            .accessibilityIdentifier("transcript.tool.\(block.name)")
        }
        .disclosureGroupStyle(.automatic)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if block.isError {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.red.opacity(0.4), lineWidth: 1)
            }
        }
    }

    private var resultTruncationNote: String {
        guard let length = block.resultLength, let shown = block.result?.count, length > shown else {
            return "Output truncated"
        }
        return "Showing \(shown.formatted()) of \(length.formatted()) characters"
    }

    /// MCP tools arrive as `mcp__server__tool`, which is unreadable in a narrow row.
    private var displayName: String {
        guard block.name.hasPrefix("mcp__") else { return block.name }
        let parts = block.name.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return block.name }
        return "\(parts[1]) · \(parts[0])"
    }

    private var icon: String {
        switch block.name {
        case "Bash", "BashOutput": return "terminal"
        case "Read", "NotebookRead": return "doc.text"
        case "Glob", "Grep", "ToolSearch": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2"
        default: return block.name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    @ViewBuilder
    private func labelled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Diff

/// A file edit, shown as removed/added rather than as the tool call that produced it.
struct DiffBlockView: View {
    let block: TranscriptBlock.DiffBlock

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let old = block.oldText, !old.isEmpty {
                    DiffSide(text: old, tint: .red, symbol: "minus", truncated: block.oldTruncated)
                }
                if let next = block.newText, !next.isEmpty {
                    DiffSide(text: next, tint: .green, symbol: "plus", truncated: block.newTruncated)
                }
                if let result = block.result, !result.isEmpty {
                    Text(result)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: block.isError ? "exclamationmark.triangle" : "square.and.pencil")
                    .font(.caption)
                    .foregroundStyle(block.isError ? .red : .orange)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(block.fileName ?? block.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let path = block.filePath {
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Spacer(minLength: 0)

                Text(block.oldText == nil ? "new file" : "edit")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("transcript.diff")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DiffSide: View {
    let text: String
    let tint: Color
    let symbol: String
    let truncated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.caption2.weight(.bold))
                Text(symbol == "minus" ? "Removed" : "Added").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(tint)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if truncated { TruncationNote() }
        }
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
