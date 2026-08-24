import Foundation

/// Collapses a block list into what the transcript actually renders.
///
/// A real turn runs a dozen tools between two sentences. Rendered one card each, the prose — the
/// part a human is reading — is buried under machinery. Consecutive tool calls and edits therefore
/// fold into ONE summary row ("Ran a command, read a file") that opens the detail on demand, which
/// is how every mature agent client presents this.
///
/// Pure and separately testable: the summary label is the most-read text on the screen, and it is
/// generated rather than authored, so it needs to be pinned by tests rather than eyeballed.
enum TranscriptTimeline {
    /// One rendered row.
    enum Item: Identifiable, Sendable, Hashable {
        /// Prose, reasoning, or a user message — rendered inline.
        case block(TranscriptBlock)
        /// A run of consecutive tool calls and edits, rendered as one expandable row.
        case steps(StepGroup)

        var id: String {
            switch self {
            case .block(let b): return b.id
            case .steps(let g): return g.id
            }
        }
    }

    struct StepGroup: Identifiable, Sendable, Hashable {
        /// The first step's id — stable across re-fetches, so the row keeps its identity.
        var id: String
        var steps: [TranscriptBlock]
        /// "Ran a command, read a file"
        var summary: String
        var addedLines: Int
        var removedLines: Int
        /// True while any step is still awaiting its result.
        var isRunning: Bool

        var hasDiffStats: Bool { addedLines > 0 || removedLines > 0 }
    }

    /// Build the rendered timeline from the server's flat block list.
    static func build(_ blocks: [TranscriptBlock]) -> [Item] {
        var items: [Item] = []
        var run: [TranscriptBlock] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            items.append(.steps(makeGroup(run)))
            run.removeAll()
        }

        for block in blocks {
            switch block {
            case .toolCall, .diff:
                run.append(block)
            case .user, .assistant, .thinking:
                // ⚠️ Prose BREAKS a run. The agent acting, speaking, then acting again is real
                // structure — merging across the sentence would reorder the story of the turn.
                flushRun()
                items.append(.block(block))
            }
        }
        flushRun()
        return items
    }

    private static func makeGroup(_ steps: [TranscriptBlock]) -> StepGroup {
        var added = 0
        var removed = 0
        var running = false
        for step in steps {
            switch step {
            case .diff(let d):
                added += d.addedLines
                removed += d.removedLines
            case .toolCall(let t):
                if t.isRunning { running = true }
            default:
                break
            }
        }
        return StepGroup(
            id: steps.first?.id ?? UUID().uuidString,
            steps: steps,
            summary: summarize(steps),
            addedLines: added,
            removedLines: removed,
            isRunning: running
        )
    }

    // MARK: - Summary text

    /// What a step did, in the form the summary sentence uses.
    private enum Activity: Int, CaseIterable {
        case created, edited, ranCommand, readFile, searched, fetched, delegated, other

        /// Ordered so the sentence leads with the consequential things — a file created or edited
        /// matters more to a reader scanning the transcript than a search that supported it.
        var rank: Int { rawValue }

        func phrase(_ count: Int) -> String {
            switch self {
            case .created: return count == 1 ? "created a file" : "created \(count) files"
            case .edited: return count == 1 ? "edited a file" : "edited \(count) files"
            case .ranCommand: return count == 1 ? "ran a command" : "ran \(count) commands"
            case .readFile: return count == 1 ? "read a file" : "read \(count) files"
            case .searched: return count == 1 ? "searched" : "searched \(count) times"
            case .fetched: return count == 1 ? "fetched a page" : "fetched \(count) pages"
            case .delegated: return count == 1 ? "ran an agent" : "ran \(count) agents"
            case .other: return count == 1 ? "used a tool" : "used \(count) tools"
            }
        }
    }

    private static func activity(of block: TranscriptBlock) -> Activity {
        switch block {
        case .diff(let d):
            // A whole-file write with no prior side is a creation, not an edit.
            return d.oldText == nil ? .created : .edited
        case .toolCall(let t):
            switch t.name {
            case "Bash", "BashOutput", "KillShell": return .ranCommand
            case "Read", "NotebookRead": return .readFile
            case "Grep", "Glob", "ToolSearch": return .searched
            case "WebFetch", "WebSearch": return .fetched
            case "Task", "Agent": return .delegated
            default: return .other
            }
        default:
            return .other
        }
    }

    /// "Ran a command, read a file" — sentence-cased, at most three clauses.
    static func summarize(_ steps: [TranscriptBlock]) -> String {
        guard !steps.isEmpty else { return "No steps" }

        var counts: [Activity: Int] = [:]
        for step in steps { counts[activity(of: step), default: 0] += 1 }

        var phrases = counts
            .sorted { lhs, rhs in
                lhs.key.rank == rhs.key.rank ? lhs.value > rhs.value : lhs.key.rank < rhs.key.rank
            }
            .map { $0.key.phrase($0.value) }

        // ⚠️ Cap the clauses. A long run can touch six categories, and a summary that wraps to
        // three lines defeats the point of collapsing the run in the first place.
        if phrases.count > 3 {
            let shown = phrases.prefix(2)
            let remaining = steps.count - counts
                .sorted { $0.key.rank < $1.key.rank }
                .prefix(2)
                .reduce(0) { $0 + $1.value }
            phrases = Array(shown) + ["\(remaining) more"]
        }

        let sentence = phrases.joined(separator: ", ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    /// Label for one step inside the sheet: "Used Edit", "Ran <description>".
    static func stepLabel(_ block: TranscriptBlock) -> (verb: String, detail: String?) {
        switch block {
        case .toolCall(let t):
            if activity(of: block) == .ranCommand { return ("Ran", t.summary) }
            return ("Used", t.name.hasPrefix("mcp__") ? prettyMCPName(t.name) : t.name)
        case .diff(let d):
            return (d.oldText == nil ? "Created" : "Edited", d.fileName ?? d.filePath)
        default:
            return ("Step", nil)
        }
    }

    /// `mcp__gortex__search` reads as noise in a narrow row; `search · gortex` does not.
    static func prettyMCPName(_ raw: String) -> String {
        guard raw.hasPrefix("mcp__") else { return raw }
        let parts = raw.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return raw }
        return "\(parts[1]) · \(parts[0])"
    }
}
