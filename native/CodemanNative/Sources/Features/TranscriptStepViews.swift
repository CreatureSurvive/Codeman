import SwiftUI

/// A run of tool calls, collapsed to one line.
///
/// Modelled on how mature agent clients present this: the transcript stays readable prose, and the
/// machinery behind it is one tap away rather than inline. The row carries just enough to decide
/// whether to open it — what happened, how much code changed, and whether it is still going.
struct ToolStepRow: View {
    let group: TranscriptTimeline.StepGroup
    let sessionID: String

    @State private var showingSteps = false

    var body: some View {
        Button {
            showingSteps = true
        } label: {
            HStack(spacing: 8) {
                if group.isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(group.isRunning ? "Running" : group.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if group.hasDiffStats {
                    DiffStatBadge(added: group.addedLines, removed: group.removedLines)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transcript.steps")
        .transcriptMessageMenu(
            state: group.isRunning ? .processing : .settled,
            text: group.summary,
            sessionID: sessionID
        )
        .sheet(isPresented: $showingSteps) {
            ToolStepSheet(group: group, sessionID: sessionID)
        }
    }
}

/// `+78 -0`, the at-a-glance size of a change.
struct DiffStatBadge: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            if added > 0 {
                Text("+\(added)").foregroundStyle(.green)
            }
            if removed > 0 {
                Text("-\(removed)").foregroundStyle(.red)
            }
        }
        .font(.caption.weight(.medium).monospacedDigit())
        .accessibilityLabel("\(added) added, \(removed) removed")
    }
}

/// The steps behind one summary row, as a list you can drill into.
struct ToolStepSheet: View {
    let group: TranscriptTimeline.StepGroup
    let sessionID: String

    @Environment(\.dismiss) private var dismiss

    /// Roughly the content height: a nav bar plus one row per step, capped before it would be
    /// taller than `.medium` anyway.
    static func detents(for stepCount: Int) -> Set<PresentationDetent> {
        let estimated = 90 + Double(min(stepCount, 6)) * 62
        return [.height(estimated), .large]
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(group.steps.enumerated()), id: \.element.id) { index, step in
                    NavigationLink {
                        ToolStepDetailView(step: step, sessionID: sessionID)
                    } label: {
                        StepRowLabel(step: step, isLast: index == group.steps.count - 1)
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .navigationTitle(group.summary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .inAppBrowser()
        // ⚠️ Sized to the run, not a fixed half-screen. Most groups are one or two steps, and a
        // `.medium` detent leaves them stranded in an empty sheet; a long run still gets `.large`.
        .presentationDetents(Self.detents(for: group.steps.count))
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("transcript.stepSheet")
    }
}

/// One step in the sheet, with the connector line that makes a run read as a sequence.
private struct StepRowLabel: View {
    let step: TranscriptBlock
    let isLast: Bool

    var body: some View {
        let label = TranscriptTimeline.stepLabel(step)
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                // Drawn only between rows, so the last step does not trail a line into nothing.
                if !isLast {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 2)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(label.verb).font(.body)
                    if let detail = label.detail {
                        Text(detail)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if case .diff(let d) = step, d.addedLines > 0 || d.removedLines > 0 {
                    DiffStatBadge(added: d.addedLines, removed: d.removedLines)
                }
                if case .toolCall(let t) = step, t.isError {
                    Label("Failed", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.bottom, 10)

            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("transcript.step")
    }

    private var icon: String {
        switch step {
        case .diff: return "square.and.pencil"
        case .toolCall(let t):
            if t.isError { return "exclamationmark.triangle" }
            switch t.name {
            case "Bash", "BashOutput": return "chevron.left.forwardslash.chevron.right"
            case "Read", "NotebookRead": return "doc.text"
            case "Grep", "Glob", "ToolSearch": return "magnifyingglass"
            case "WebFetch", "WebSearch": return "globe"
            case "Task", "Agent": return "person.2"
            default: return "wrench.and.screwdriver"
            }
        default: return "circle"
        }
    }

    private var tint: Color {
        if case .toolCall(let t) = step, t.isError { return .red }
        if case .diff = step { return .orange }
        return .secondary
    }
}

/// The full detail of one step: command and output, or the diff it applied.
struct ToolStepDetailView: View {
    let step: TranscriptBlock
    let sessionID: String

    @State private var zoomed: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch step {
                case .toolCall(let t): toolDetail(t)
                case .diff(let d): DiffView(diff: d)
                default: EmptyView()
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { zoomed.map(ZoomedImage.init) }, set: { zoomed = $0?.image })) { item in
            TranscriptImageViewer(image: item.image)
        }
        .accessibilityIdentifier("transcript.stepDetail")
    }

    private struct ZoomedImage: Identifiable {
        let image: UIImage
        var id: String { "\(image.hashValue)" }
    }

    private var title: String {
        switch step {
        case .toolCall(let t): return t.name.hasPrefix("mcp__") ? TranscriptTimeline.prettyMCPName(t.name) : t.name
        case .diff(let d): return d.fileName ?? d.name
        default: return "Step"
        }
    }

    @ViewBuilder
    private func toolDetail(_ t: TranscriptBlock.ToolCallBlock) -> some View {
        if let input = t.input, !input.isEmpty {
            section(t.summary != nil ? "Command" : "Input") {
                CodeBlockView(code: displayInput(t), language: nil)
                if t.inputTruncated { TruncationCaption() }
            }
        }

        if t.isRunning {
            Label("Still running", systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        if let result = t.result, !result.isEmpty {
            section(t.isError ? "Error" : "Output") {
                CodeBlockView(code: result, language: nil)
                if t.resultTruncated {
                    Text(truncationNote(t))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if !t.images.isEmpty {
            section("Images") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(t.images) { ref in
                            TranscriptImageView(sessionID: sessionID, reference: ref) { zoomed = $0 }
                        }
                    }
                }
            }
        }
    }

    /// A Bash step shows the raw command, not the JSON wrapper around it — the wrapper is noise
    /// when the whole detail view exists to show what ran.
    private func displayInput(_ t: TranscriptBlock.ToolCallBlock) -> String {
        guard t.name == "Bash" || t.name == "BashOutput",
              let input = t.input,
              let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String
        else { return t.input ?? "" }
        return command
    }

    private func truncationNote(_ t: TranscriptBlock.ToolCallBlock) -> String {
        guard let length = t.resultLength, let shown = t.result?.count, length > shown else {
            return "Output truncated"
        }
        return "Showing \(shown.formatted()) of \(length.formatted()) characters"
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct TruncationCaption: View {
    var body: some View {
        Label("Truncated", systemImage: "scissors")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

/// A file edit, rendered as a unified diff.
///
/// Line-oriented rather than a raw before/after dump: the transcript gives both sides in full, and
/// showing them as two opaque blobs makes the reader diff them by eye. Lines are matched by a
/// longest-common-subsequence walk so unchanged context stays unmarked.
struct DiffView: View {
    let diff: TranscriptBlock.DiffBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let path = diff.filePath {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                DiffStatBadge(added: diff.addedLines, removed: diff.removedLines)
                if diff.oldText == nil {
                    Text("new file").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(line.kind.marker)
                                .font(.system(.caption2, design: .monospaced).weight(.bold))
                                .foregroundStyle(line.kind.tint)
                                .frame(width: 10, alignment: .leading)
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(line.kind == .context ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.kind.background)
                    }
                }
            }
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if diff.oldTruncated || diff.newTruncated { TruncationCaption() }

            if let result = diff.result, !result.isEmpty {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("transcript.diffView")
    }

    private var lines: [DiffLine] {
        DiffLine.build(old: diff.oldText, new: diff.newText)
    }
}

/// One rendered diff line.
struct DiffLine: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case context, added, removed

        var marker: String {
            switch self {
            case .context: return " "
            case .added: return "+"
            case .removed: return "-"
            }
        }

        var tint: Color {
            switch self {
            case .context: return .secondary
            case .added: return .green
            case .removed: return .red
            }
        }

        var background: Color {
            switch self {
            case .context: return .clear
            case .added: return .green.opacity(0.12)
            case .removed: return .red.opacity(0.12)
            }
        }
    }

    var kind: Kind
    var text: String

    /// Longest-common-subsequence diff over lines.
    ///
    /// ⚠️ Bounded on purpose. LCS is O(n·m), and an `Edit` on a large file can hand us thousands
    /// of lines a side — enough to stall the main thread while someone is scrolling. Past the cap
    /// this degrades to a plain removed-then-added rendering, which is still correct, just without
    /// unchanged context called out.
    static let maxLinesForLCS = 400

    static func build(old: String?, new: String?) -> [DiffLine] {
        let oldLines = old.map { $0.components(separatedBy: "\n") } ?? []
        let newLines = new.map { $0.components(separatedBy: "\n") } ?? []

        if oldLines.isEmpty { return newLines.map { DiffLine(kind: .added, text: $0) } }
        if newLines.isEmpty { return oldLines.map { DiffLine(kind: .removed, text: $0) } }
        if oldLines.count > maxLinesForLCS || newLines.count > maxLinesForLCS {
            return oldLines.map { DiffLine(kind: .removed, text: $0) }
                + newLines.map { DiffLine(kind: .added, text: $0) }
        }

        // table[i][j] = LCS length of oldLines[i...] and newLines[j...]
        var table = Array(
            repeating: Array(repeating: 0, count: newLines.count + 1),
            count: oldLines.count + 1
        )
        for i in stride(from: oldLines.count - 1, through: 0, by: -1) {
            for j in stride(from: newLines.count - 1, through: 0, by: -1) {
                table[i][j] = oldLines[i] == newLines[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var out: [DiffLine] = []
        var i = 0
        var j = 0
        while i < oldLines.count, j < newLines.count {
            if oldLines[i] == newLines[j] {
                out.append(DiffLine(kind: .context, text: oldLines[i]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                out.append(DiffLine(kind: .removed, text: oldLines[i]))
                i += 1
            } else {
                out.append(DiffLine(kind: .added, text: newLines[j]))
                j += 1
            }
        }
        while i < oldLines.count {
            out.append(DiffLine(kind: .removed, text: oldLines[i]))
            i += 1
        }
        while j < newLines.count {
            out.append(DiffLine(kind: .added, text: newLines[j]))
            j += 1
        }
        return out
    }
}
