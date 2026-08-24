import Foundation
import Testing
@testable import Codeman

/// Decoding, merging and markdown for the native transcript view.
///
/// The JSON here is the server's real wire shape (`src/transcript-blocks.ts`), not an
/// approximation — the Swift enum and the TypeScript union have to agree field for field, and
/// these fixtures are where that agreement is pinned.
struct TranscriptDecodingTests {
    private func decode(_ json: String) throws -> TranscriptResponse {
        try JSONDecoder().decode(TranscriptResponse.self, from: Data(json.utf8))
    }

    @Test("decodes every block kind the server emits")
    func decodesAllKinds() throws {
        let response = try decode("""
        {"available":true,"truncated":false,"totalBlocks":5,"blocks":[
          {"id":"1","kind":"user","text":"hello","images":[{"ref":"u1:1","mediaType":"image/png","bytes":2048}]},
          {"id":"2","kind":"thinking","text":"pondering"},
          {"id":"3","kind":"assistant","text":"hi"},
          {"id":"4","kind":"toolCall","name":"Bash","summary":"ls","result":"a.ts","resultLength":4},
          {"id":"5","kind":"diff","name":"Edit","filePath":"/repo/a.ts","oldText":"a","newText":"b"}
        ]}
        """)

        #expect(response.available)
        #expect(response.blocks.count == 5)

        guard case .user(let u) = response.blocks[0] else { Issue.record("not a user block"); return }
        #expect(u.text == "hello")
        #expect(u.images.map(\.ref) == ["u1:1"])
        #expect(u.images.first?.mediaType == "image/png")

        guard case .toolCall(let t) = response.blocks[3] else { Issue.record("not a tool call"); return }
        #expect(t.name == "Bash")
        #expect(t.result == "a.ts")
        #expect(!t.isRunning)

        guard case .diff(let d) = response.blocks[4] else { Issue.record("not a diff"); return }
        #expect(d.fileName == "a.ts")
        #expect(d.oldText == "a")
    }

    // The transcript format belongs to Claude Code. A kind added upstream must cost one block,
    // not the whole conversation — a strict array decode would blank the entire view.
    @Test("skips an unknown block kind without losing the rest")
    func skipsUnknownKinds() throws {
        let response = try decode("""
        {"available":true,"blocks":[
          {"id":"1","kind":"user","text":"before"},
          {"id":"2","kind":"somethingNew","payload":{"a":1}},
          {"id":"3","kind":"assistant","text":"after"}
        ]}
        """)
        #expect(response.blocks.count == 2)
        #expect(response.blocks.map(\.id) == ["1", "3"])
    }

    @Test("a malformed block does not stall the decode loop")
    func malformedBlockTerminates() throws {
        // A block missing its required `id` cannot decode; the loop must still advance past it.
        let response = try decode("""
        {"available":true,"blocks":[
          {"kind":"user","text":"no id"},
          {"id":"2","kind":"user","text":"fine"}
        ]}
        """)
        #expect(response.blocks.map(\.id) == ["2"])
    }

    @Test("a tool call with no result yet reads as running")
    func pendingToolCall() throws {
        let response = try decode("""
        {"available":true,"blocks":[{"id":"1","kind":"toolCall","name":"Bash","summary":"sleep 30"}]}
        """)
        guard case .toolCall(let t) = response.blocks[0] else { Issue.record("not a tool call"); return }
        #expect(t.isRunning)
        #expect(t.result == nil)
    }

    // A failed call has resolved — showing a spinner next to an error would be a lie.
    @Test("a failed tool call is not running")
    func failedToolCallIsNotRunning() throws {
        let response = try decode("""
        {"available":true,"blocks":[{"id":"1","kind":"toolCall","name":"Bash","isError":true}]}
        """)
        guard case .toolCall(let t) = response.blocks[0] else { Issue.record("not a tool call"); return }
        #expect(t.isError)
        #expect(!t.isRunning)
    }

    @Test("carries the server's reason when no transcript exists")
    func unavailableCarriesReason() throws {
        let response = try decode(#"{"available":false,"reason":"shell sessions write no Claude transcript","blocks":[]}"#)
        #expect(!response.available)
        #expect(response.reason?.contains("shell") == true)
    }

    @Test("parses Claude's fractional-second timestamps")
    func parsesTimestamps() throws {
        let response = try decode("""
        {"available":true,"blocks":[
          {"id":"1","kind":"user","text":"a","timestamp":"2026-08-23T19:28:46.969Z"},
          {"id":"2","kind":"user","text":"b","timestamp":"2026-08-23T19:28:47Z"},
          {"id":"3","kind":"user","text":"c","timestamp":"not a date"}
        ]}
        """)
        #expect(response.blocks[0].timestamp != nil)
        #expect(response.blocks[1].timestamp != nil)
        // A bad stamp only drives a relative-time label, so it degrades instead of failing.
        #expect(response.blocks[2].timestamp == nil)
    }
}

struct TranscriptParserTests {
    private func response(_ json: String) throws -> TranscriptResponse {
        try JSONDecoder().decode(TranscriptResponse.self, from: Data(json.utf8))
    }

    @Test("keeps server order and does not duplicate a re-sent block")
    func dedupesAcrossFetches() async throws {
        let parser = TranscriptParser()
        let page = try response("""
        {"available":true,"blocks":[
          {"id":"1","kind":"user","text":"one"},
          {"id":"2","kind":"assistant","text":"two"}
        ]}
        """)
        await parser.ingest(page)
        let snapshot = await parser.ingest(page)

        #expect(snapshot.blocks.map(\.id) == ["1", "2"])
    }

    // The server re-sends a tool call once its result lands, under the same id. Appending would
    // show the command twice, one copy stuck on "running" forever.
    @Test("a re-sent tool call is replaced in place, not appended")
    func replacesInPlace() async throws {
        let parser = TranscriptParser()
        await parser.ingest(try response("""
        {"available":true,"blocks":[{"id":"t","kind":"toolCall","name":"Bash","summary":"ls"}]}
        """))
        let snapshot = await parser.ingest(try response("""
        {"available":true,"blocks":[{"id":"t","kind":"toolCall","name":"Bash","summary":"ls","result":"a.ts"}]}
        """))

        #expect(snapshot.blocks.count == 1)
        guard case .toolCall(let t) = snapshot.blocks[0] else { Issue.record("not a tool call"); return }
        #expect(t.result == "a.ts")
        #expect(!t.isRunning)
    }

    @Test("appends genuinely new blocks after the ones already held")
    func appendsNewBlocks() async throws {
        let parser = TranscriptParser()
        await parser.ingest(try response(#"{"available":true,"blocks":[{"id":"1","kind":"user","text":"one"}]}"#))
        let snapshot = await parser.ingest(try response("""
        {"available":true,"blocks":[
          {"id":"1","kind":"user","text":"one"},
          {"id":"2","kind":"assistant","text":"two"}
        ]}
        """))
        #expect(snapshot.blocks.map(\.id) == ["1", "2"])
    }

    @Test("reset drops the thread, because /clear starts an unrelated conversation")
    func resetClears() async throws {
        let parser = TranscriptParser()
        await parser.ingest(try response(#"{"available":true,"blocks":[{"id":"1","kind":"user","text":"one"}]}"#))
        await parser.reset()
        let snapshot = await parser.snapshot()
        #expect(snapshot.blocks.isEmpty)
        #expect(snapshot.availability == .unknown)
    }

    @Test("surfaces availability so an empty view can explain itself")
    func tracksAvailability() async throws {
        let parser = TranscriptParser()
        let snapshot = await parser.ingest(try response(#"{"available":false,"reason":"no transcript yet","blocks":[]}"#))
        #expect(snapshot.availability == .unavailable("no transcript yet"))
    }
}

struct MarkdownBlockTests {
    @Test("splits a fenced code block out of surrounding prose")
    func splitsFencedCode() {
        let blocks = MarkdownBlock.parse("""
        Here is a command:

        ```bash
        ls -la
        echo done
        ```

        That was it.
        """)

        #expect(blocks.count == 3)
        #expect(blocks[0].kind == .paragraph)
        #expect(blocks[1].kind == .code(language: "bash"))
        // The newline is the whole point: rendered as one inline run it would be unreadable.
        #expect(blocks[1].content == "ls -la\necho done")
        #expect(blocks[2].kind == .paragraph)
    }

    // A turn still being written is routinely cut mid-fence; the opened block must still render.
    @Test("an unterminated fence runs to the end instead of swallowing everything as prose")
    func unterminatedFence() {
        let blocks = MarkdownBlock.parse("intro\n\n```swift\nlet x = 1")
        #expect(blocks.count == 2)
        #expect(blocks[1].kind == .code(language: "swift"))
        #expect(blocks[1].content == "let x = 1")
    }

    @Test("recognises headings, bullets, numbers and quotes")
    func recognisesBlockKinds() {
        let blocks = MarkdownBlock.parse("""
        ## Findings

        - first
        - second
        1. step one
        2) step two
        > a note
        """)

        #expect(blocks[0].kind == .heading(2))
        #expect(blocks[0].content == "Findings")
        #expect(blocks[1].kind == .bullet(depth: 0))
        #expect(blocks[3].kind == .numbered(marker: "1.", depth: 0))
        #expect(blocks[4].kind == .numbered(marker: "2.", depth: 0))
        #expect(blocks[5].kind == .quote)
        #expect(blocks[5].content == "a note")
    }

    @Test("indented list items keep their nesting depth")
    func nestedBullets() {
        let blocks = MarkdownBlock.parse("- top\n  - nested")
        #expect(blocks[0].kind == .bullet(depth: 0))
        #expect(blocks[1].kind == .bullet(depth: 1))
    }

    // `#hashtag` and `1985. a year` are prose, not structure.
    @Test("does not mistake prose for a heading or a list")
    func avoidsFalsePositives() {
        let blocks = MarkdownBlock.parse("#hashtag not a heading")
        #expect(blocks[0].kind == .paragraph)
        let numbered = MarkdownBlock.parse("1985 was a year")
        #expect(numbered[0].kind == .paragraph)
    }

    @Test("joins consecutive prose lines into one paragraph")
    func joinsParagraphLines() {
        let blocks = MarkdownBlock.parse("line one\nline two\n\nsecond para")
        #expect(blocks.count == 2)
        #expect(blocks[0].content == "line one\nline two")
    }

    @Test("unparseable inline markdown still renders as readable text")
    func inlineFallback() {
        let attributed = MarkdownBlock.inline("a **bold** claim with an [unclosed link")
        #expect(String(attributed.characters).contains("claim"))
    }
}

/// Empty-state classification.
///
/// Regression cover for the worst possible failure of this screen: reporting a long, healthy
/// conversation as "Nothing yet". A server without the transcript route answers 404, and treating
/// that like an empty list told the user their history did not exist.
struct TranscriptFailureClassificationTests {
    @Test("a missing route is distinguished from a missing resource")
    func missingEndpointVsMissingResource() {
        // Fastify's own not-found body — the server has no such route.
        let noRoute = APIError.server(
            status: 404,
            code: .notFound,
            message: "Route GET:/api/sessions/abc/transcript not found"
        )
        #expect(noRoute.isMissingEndpoint)

        // A handler's own 404 — the route exists, the session does not.
        let noSession = APIError.server(status: 404, code: .notFound, message: "Session not found")
        #expect(!noSession.isMissingEndpoint)

        // Other statuses are never an endpoint problem.
        #expect(!APIError.server(status: 500, code: .internalError, message: "Route boom").isMissingEndpoint)
    }

    @Test("marking unsupported does not discard blocks already on screen")
    func unsupportedKeepsBlocks() async throws {
        let parser = TranscriptParser()
        let page = try JSONDecoder().decode(
            TranscriptResponse.self,
            from: Data(#"{"available":true,"blocks":[{"id":"1","kind":"user","text":"one"}]}"#.utf8)
        )
        await parser.ingest(page)
        await parser.markUnsupported()
        let snapshot = await parser.snapshot()

        #expect(snapshot.availability == .unsupported)
        #expect(snapshot.blocks.count == 1)
    }
}

/// Grouping and summary text.
///
/// The summary line is generated, not authored, and it is the most-read text on the screen — a
/// wrong count or a mislabelled verb misdescribes what the agent did.
struct TranscriptTimelineTests {
    private func tool(_ id: String, _ name: String, summary: String? = nil, running: Bool = false) -> TranscriptBlock {
        .toolCall(.init(id: id, timestamp: nil, name: name, summary: summary, input: nil,
                        inputTruncated: false, result: running ? nil : "ok", resultTruncated: false,
                        resultLength: nil, isError: false, images: []))
    }

    private func diff(_ id: String, old: String?, new: String?, added: Int = 0, removed: Int = 0) -> TranscriptBlock {
        .diff(.init(id: id, timestamp: nil, name: old == nil ? "Write" : "Edit", filePath: "/repo/a.ts",
                    oldText: old, newText: new, oldTruncated: false, newTruncated: false,
                    addedLines: added, removedLines: removed, isError: false, result: nil))
    }

    private func prose(_ id: String, _ text: String) -> TranscriptBlock {
        .assistant(.init(id: id, timestamp: nil, text: text, truncated: false))
    }

    @Test("folds a run of tools into one row")
    func foldsRuns() {
        let items = TranscriptTimeline.build([
            prose("p1", "Doing it."),
            tool("t1", "Bash"), tool("t2", "Read"), tool("t3", "Bash"),
            prose("p2", "Done."),
        ])
        #expect(items.count == 3)
        guard case .steps(let group) = items[1] else { Issue.record("expected a step group"); return }
        #expect(group.steps.count == 3)
    }

    // ⚠️ Pins the invariant the transcript's scroll-to-bottom depends on. A run folds into a row
    // keyed by its FIRST step, so when a turn ends on tool calls the last BLOCK id is not a
    // rendered id at all. Targeting it made `scrollTo` a silent no-op — the jump button and the
    // follow-the-tail scroll both did nothing. The scroll target must come from the timeline.
    @Test("the last rendered row is keyed by the run's first step, not the last block")
    func lastRowIdIsNotTheLastBlockId() {
        let blocks = [prose("p1", "Working."), tool("t1", "Bash"), tool("t2", "Read"), tool("t3", "Bash")]
        let items = TranscriptTimeline.build(blocks)

        #expect(items.last?.id == "t1")
        #expect(items.last?.id != blocks.last?.id)
        #expect(!items.map(\.id).contains(blocks.last!.id))
    }

    // The agent speaking between two actions is real structure; merging across it would reorder
    // the story of the turn.
    @Test("prose breaks a run rather than being absorbed into it")
    func proseBreaksRuns() {
        let items = TranscriptTimeline.build([
            tool("t1", "Bash"), prose("p1", "hmm"), tool("t2", "Bash"),
        ])
        #expect(items.count == 3)
        if case .block = items[1] {} else { Issue.record("middle item should be prose") }
    }

    @Test("summarises mixed activity in plain language")
    func summarises() {
        #expect(TranscriptTimeline.summarize([tool("1", "Bash")]) == "Ran a command")
        #expect(TranscriptTimeline.summarize([tool("1", "Bash"), tool("2", "Bash")]) == "Ran 2 commands")
        #expect(TranscriptTimeline.summarize([tool("1", "Bash"), tool("2", "Read")]) == "Ran a command, read a file")
        #expect(TranscriptTimeline.summarize([diff("1", old: nil, new: "x"), tool("2", "Bash"), tool("3", "Bash")])
                == "Created a file, ran 2 commands")
    }

    // A summary that wraps to three lines defeats the point of collapsing the run.
    @Test("caps the clause count on a long, varied run")
    func capsClauses() {
        let summary = TranscriptTimeline.summarize([
            diff("1", old: nil, new: "x"), diff("2", old: "a", new: "b"),
            tool("3", "Bash"), tool("4", "Read"), tool("5", "Grep"), tool("6", "WebFetch"),
        ])
        #expect(summary.components(separatedBy: ", ").count == 3)
        #expect(summary.hasSuffix("more"))
    }

    @Test("aggregates diff stats across the run and reports running state")
    func aggregates() {
        let items = TranscriptTimeline.build([
            diff("1", old: "a", new: "b", added: 12, removed: 3),
            diff("2", old: nil, new: "c", added: 66, removed: 0),
            tool("3", "Bash", running: true),
        ])
        guard case .steps(let group) = items[0] else { Issue.record("expected a step group"); return }
        #expect(group.addedLines == 78)
        #expect(group.removedLines == 3)
        #expect(group.isRunning)
    }

    @Test("labels a step the way the sheet shows it")
    func stepLabels() {
        #expect(TranscriptTimeline.stepLabel(tool("1", "Bash", summary: "npm test")).verb == "Ran")
        #expect(TranscriptTimeline.stepLabel(tool("1", "Bash", summary: "npm test")).detail == "npm test")
        #expect(TranscriptTimeline.stepLabel(tool("1", "Edit")).detail == "Edit")
        #expect(TranscriptTimeline.stepLabel(diff("1", old: "a", new: "b")).verb == "Edited")
        #expect(TranscriptTimeline.stepLabel(diff("1", old: nil, new: "b")).verb == "Created")
        #expect(TranscriptTimeline.prettyMCPName("mcp__gortex__search") == "search · gortex")
    }
}

struct DiffLineTests {
    @Test("marks unchanged lines as context and only the real change as +/-")
    func unifiedDiff() {
        let lines = DiffLine.build(old: "one\ntwo\nthree", new: "one\nTWO\nthree")
        #expect(lines.map(\.kind) == [.context, .removed, .added, .context])
        #expect(lines[1].text == "two")
        #expect(lines[2].text == "TWO")
    }

    @Test("a new file is all additions")
    func newFile() {
        let lines = DiffLine.build(old: nil, new: "a\nb")
        #expect(lines.allSatisfy { $0.kind == .added })
        #expect(lines.count == 2)
    }

    // LCS is O(n·m); a large Edit would stall the main thread mid-scroll. Past the cap the
    // rendering degrades to removed-then-added, which is still correct.
    @Test("falls back to a flat rendering beyond the LCS cap instead of stalling")
    func boundedWork() {
        let big = (0..<(DiffLine.maxLinesForLCS + 10)).map(String.init).joined(separator: "\n")
        let lines = DiffLine.build(old: big, new: big)
        #expect(!lines.contains { $0.kind == .context })
        #expect(lines.count == (DiffLine.maxLinesForLCS + 10) * 2)
    }
}

/// Composer capability gating and permission-mode reading.
///
/// Both are places where a wrong answer types into somebody's live session: an unsupported harness
/// must not be offered a command it does not have, and a misread footer must not claim a mode.
struct HarnessCapabilityTests {
    @Test("offers a model menu only where a one-shot command works")
    func modelControlPerHarness() {
        guard case .directCommand(let options) = HarnessCapabilities.modelControl(for: .claude) else {
            Issue.record("claude should offer a direct model command"); return
        }
        #expect(options.contains { $0.argument == "opus" })

        // These report a model but present `/model` as an interactive picker; sending it would
        // leave a half-open menu in the pane.
        for mode in [SessionMode.codex, .opencode, .gemini, .antigravity, .pi] {
            #expect(HarnessCapabilities.modelControl(for: mode) == .readOnly, "\(mode) should be read-only")
        }

        // A shell has no model at all.
        #expect(HarnessCapabilities.modelControl(for: .shell) == nil)
        #expect(HarnessCapabilities.modelControl(for: nil) == nil)
    }

    @Test("permission cycling is claude-only")
    func permissionGating() {
        #expect(HarnessCapabilities.supportsPermissionCycling(.claude))
        for mode in [SessionMode.codex, .opencode, .gemini, .antigravity, .pi, .shell] {
            #expect(!HarnessCapabilities.supportsPermissionCycling(mode), "\(mode) should not offer cycling")
        }
    }

    // Shift+Tab, as a hardware keyboard sends it — the CLI cannot tell the difference.
    @Test("back-tab is the real CSI Z sequence")
    func backTab() {
        #expect(HarnessCapabilities.backTabSequence == "\u{1B}[Z")
    }
}

struct PermissionModeReaderTests {
    @Test("reads each mode off the footer the CLI draws")
    func readsModes() {
        #expect(PermissionModeReader.parse("⏵⏵ bypass permissions on (shift+tab to cycle)") == .bypass)
        #expect(PermissionModeReader.parse("⏸ plan mode on (shift+tab to cycle)") == .plan)
        #expect(PermissionModeReader.parse("⏵ accept edits on (shift+tab to cycle)") == .acceptEdits)
    }

    @Test("survives the footer's colouring")
    func stripsANSI() {
        let coloured = "\u{1B}[2m\u{1B}[38;5;244m⏵ accept edits on\u{1B}[0m (shift+tab)"
        #expect(PermissionModeReader.parse(coloured) == .acceptEdits)
    }

    // The footer is redrawn at the bottom; an older frame higher in the buffer reports a mode that
    // has since changed.
    @Test("takes the newest footer when the buffer holds several")
    func prefersTheLastFooter() {
        let buffer = """
        ⏵ accept edits on (shift+tab to cycle)
        some later output
        ⏸ plan mode on (shift+tab to cycle)
        """
        #expect(PermissionModeReader.parse(buffer) == .plan)
    }

    // Claiming a mode we did not read would mislabel the control.
    @Test("reports nothing when no footer is present")
    func unknownStaysNil() {
        #expect(PermissionModeReader.parse("just some terminal output\nnothing to see") == nil)
        #expect(PermissionModeReader.parse("") == nil)
    }

    @Test("ANSI stripping leaves ordinary text untouched")
    func stripKeepsText() {
        #expect(PermissionModeReader.stripANSI("plain text") == "plain text")
        #expect(PermissionModeReader.stripANSI("\u{1B}]0;title\u{07}body") == "body")
    }
}

/// Local echo of a sent message.
///
/// The bug this covers: a message sent from the composer did not appear at all. The transcript is
/// the CLI's own log, so a prompt shows up only once the CLI writes it — and a prompt sent mid-turn
/// is QUEUED, which can be minutes. Without an echo the send simply looked lost.
struct TranscriptEchoTests {
    private func user(_ id: String, _ text: String) -> TranscriptBlock {
        .user(.init(id: id, timestamp: nil, text: text, truncated: false, images: []))
    }

    @Test("an unmatched send is echoed after the server's blocks")
    func echoesUntilItLands() {
        let pending = TranscriptFeed.PendingSend(text: "ship it")
        let result = TranscriptEcho.merge(server: [user("u1", "earlier")], pending: [pending])

        #expect(result.blocks.count == 2)
        #expect(result.stillPending.count == 1)
        guard case .user(let echo) = result.blocks[1] else { Issue.record("echo should be a user block"); return }
        #expect(echo.text == "ship it")
        // Prefixed so the id can never collide with a real server block.
        #expect(echo.id.hasPrefix("pending:"))
    }

    @Test("the echo clears once the real entry arrives")
    func resolvesOnMatch() {
        let pending = TranscriptFeed.PendingSend(text: "ship it")
        let result = TranscriptEcho.merge(server: [user("u1", "ship it")], pending: [pending])

        #expect(result.stillPending.isEmpty)
        #expect(result.blocks.count == 1)
        #expect(result.blocks[0].id == "u1")
    }

    @Test("matching ignores surrounding whitespace")
    func trimsWhenMatching() {
        let pending = TranscriptFeed.PendingSend(text: "ship it")
        let result = TranscriptEcho.merge(server: [user("u1", "  ship it\n")], pending: [pending])
        #expect(result.stillPending.isEmpty)
    }

    // Sending the same message twice is legitimate; clearing both against one real entry would
    // drop a message the user can still see nothing of.
    @Test("one real entry resolves only one of two identical sends")
    func resolvesOneAtATime() {
        let first = TranscriptFeed.PendingSend(text: "again")
        let second = TranscriptFeed.PendingSend(text: "again")
        let result = TranscriptEcho.merge(server: [user("u1", "again")], pending: [first, second])

        #expect(result.stillPending.count == 1)
        #expect(result.blocks.count == 2)
    }

    // Expiring on a timer would make a queued prompt vanish while it is still waiting.
    @Test("an old unmatched send keeps showing")
    func neverExpires() {
        var stale = TranscriptFeed.PendingSend(text: "queued behind a long turn")
        let result = TranscriptEcho.merge(server: [user("u1", "unrelated")], pending: [stale])
        #expect(result.stillPending.count == 1)
        stale = result.stillPending[0]
        #expect(stale.text == "queued behind a long turn")
    }

    @Test("an empty server user block never resolves a real send")
    func emptyBlocksDoNotMatch() {
        let pending = TranscriptFeed.PendingSend(text: "real message")
        // An image-only message has empty text; it must not swallow a pending send.
        let result = TranscriptEcho.merge(server: [user("u1", "   ")], pending: [pending])
        #expect(result.stillPending.count == 1)
    }
}

/// Attached images arrive as a PATH, because Codeman types into a terminal and a path is what the
/// agent can open. These pin the narrow rule that turns such a path back into a picture.
struct AttachedImagePathTests {
    @Test("finds an absolute image path in a message")
    func findsPaths() {
        let text = "/Users/me/.claude-images/paste-1787577301065.jpg the buttons should be inline"
        let matches = AttachedImagePaths.matches(in: text)
        #expect(matches.map(\.path) == ["/Users/me/.claude-images/paste-1787577301065.jpg"])
    }

    @Test("handles several attachments and ignores duplicates")
    func multiple() {
        let text = "/tmp/a.png and /tmp/b.jpeg and /tmp/a.png again"
        #expect(AttachedImagePaths.matches(in: text).map(\.path) == ["/tmp/a.png", "/tmp/b.jpeg"])
    }

    // Prose must survive: a message that is only about code should not sprout thumbnails.
    @Test("ignores non-image paths and relative fragments")
    func ignoresOthers() {
        #expect(AttachedImagePaths.matches(in: "see src/web/routes/file-routes.ts").isEmpty)
        #expect(AttachedImagePaths.matches(in: "/tmp/report.pdf and /tmp/data.json").isEmpty)
        #expect(AttachedImagePaths.matches(in: "images/logo.png is relative").isEmpty)
    }

    @Test("strips the path so the words render without it")
    func stripsPath() {
        let text = "/tmp/shot.png make the buttons inline"
        #expect(AttachedImagePaths.strippingPaths(from: text) == "make the buttons inline")
    }

    // An image sent with no words should be a picture, not an empty bubble with a blank line.
    @Test("a path-only message leaves no prose behind")
    func pathOnly() {
        #expect(AttachedImagePaths.strippingPaths(from: "/tmp/shot.png") == nil)
        #expect(AttachedImagePaths.strippingPaths(from: "  /tmp/a.png  /tmp/b.png ") == nil)
    }

    @Test("case-insensitive extensions")
    func caseInsensitive() {
        #expect(AttachedImagePaths.matches(in: "/tmp/Shot.PNG").count == 1)
        #expect(AttachedImagePaths.matches(in: "/tmp/photo.JPEG").count == 1)
    }
}

/// Control sequences sent to a running CLI.
///
/// These are the exact bytes a hardware keyboard produces; a wrong one types garbage into a live
/// session, so they are pinned rather than trusted to a comment.
struct SessionControlTests {
    @Test("interrupt is a real ESC byte")
    func interruptByte() {
        #expect(SessionControl.interrupt == "\u{1B}")
        #expect(SessionControl.interrupt.unicodeScalars.map(\.value) == [0x1B])
    }

    // Claude Code binds Up to "press up to edit queued messages".
    @Test("recall is CSI A, the up arrow")
    func recallSequence() {
        #expect(SessionControl.recallPrevious == "\u{1B}[A")
        #expect(SessionControl.recallPrevious.unicodeScalars.map(\.value) == [0x1B, 0x5B, 0x41])
    }

    // Interrupt and back-tab are different keys; swapping them would cycle permission mode when
    // the user asked to stop.
    @Test("interrupt is distinct from the permission-cycle key")
    func distinctFromBackTab() {
        #expect(SessionControl.interrupt != HarnessCapabilities.backTabSequence)
    }
}

/// Error and warning detection in agent prose.
///
/// ⚠️ Deliberately narrow. The transcript carries no `kind: "error"`, so this reads the text — and
/// a false positive paints ordinary discussion of an error red, which is worse than missing one.
struct NoticeStyleTests {
    @Test("recognises the notices Claude Code actually writes")
    func recognisesNotices() {
        #expect(NoticeStyle.classify("You've hit your monthly spend limit · raise it at claude.ai") == .error)
        #expect(NoticeStyle.classify("API Error: 500 internal") == .error)
        #expect(NoticeStyle.classify("Rate limit reached, retrying") == .error)
        #expect(NoticeStyle.classify("Warning: this will overwrite the file") == .warning)
    }

    // Ordinary prose ABOUT an error must stay ordinary prose.
    @Test("does not paint discussion of errors as an error")
    func avoidsFalsePositives() {
        #expect(NoticeStyle.classify("The error was in my scroll fix, not the parser.") == nil)
        #expect(NoticeStyle.classify("Let me check whether that request failed earlier.") == nil)
        #expect(NoticeStyle.classify("") == nil)
    }

    // These notices lead with their marker; a mid-sentence mention is not one.
    @Test("only the first non-empty line decides")
    func firstLineOnly() {
        #expect(NoticeStyle.classify("\n\nWarning: disk almost full") == .warning)
        #expect(NoticeStyle.classify("All good.\nError: ignore this line") == nil)
    }
}

/// Syntax tokenising.
///
/// The rules that matter are precedence rules: a keyword inside a string is not a keyword, and a
/// comment swallows the rest of its line. Those are what make highlighting read correctly rather
/// than sprinkling colour at random.
struct SyntaxHighlighterTests {
    private func kinds(_ line: String, _ language: SyntaxHighlighter.Language) -> [SyntaxHighlighter.Token.Kind] {
        var block = false
        return SyntaxHighlighter.tokenize(line, language: language, inBlockComment: &block).map(\.kind)
    }

    private func tokens(_ line: String, _ language: SyntaxHighlighter.Language) -> [SyntaxHighlighter.Token] {
        var block = false
        return SyntaxHighlighter.tokenize(line, language: language, inBlockComment: &block)
    }

    @Test("colours keywords, types, strings and numbers")
    func basicTokens() {
        let result = tokens(#"let count = 42"#, .swift)
        #expect(result.first { $0.text == "let" }?.kind == .keyword)
        #expect(result.first { $0.text == "42" }?.kind == .number)

        let typed = tokens("struct Session {", .swift)
        #expect(typed.first { $0.text == "Session" }?.kind == .type)
    }

    // The rule that makes highlighting correct instead of decorative.
    @Test("a keyword inside a string stays a string")
    func stringsWinOverKeywords() {
        let result = tokens(#"let s = "return if else""#, .swift)
        let string = result.first { $0.kind == .string }
        #expect(string?.text == #""return if else""#)
        #expect(!result.contains { $0.text == "return" && $0.kind == .keyword })
    }

    @Test("an escaped quote does not end the string early")
    func escapedQuotes() {
        let result = tokens(#"let s = "a\"b" + x"#, .swift)
        #expect(result.first { $0.kind == .string }?.text == #""a\"b""#)
    }

    @Test("a line comment swallows the rest of the line")
    func lineComments() {
        let result = tokens("let x = 1 // return true", .swift)
        #expect(result.last?.kind == .comment)
        #expect(result.last?.text == "// return true")
        // Python and shell use a different marker.
        #expect(kinds("x = 1  # note", .python).last == .comment)
        #expect(kinds("echo hi # note", .shell).last == .comment)
    }

    // Block-comment state must carry across lines or the closing line loses its colour.
    @Test("block comments span lines through the inout flag")
    func blockComments() {
        var block = false
        _ = SyntaxHighlighter.tokenize("/* start", language: .swift, inBlockComment: &block)
        #expect(block)
        let middle = SyntaxHighlighter.tokenize("still comment", language: .swift, inBlockComment: &block)
        #expect(middle.allSatisfy { $0.kind == .comment })
        _ = SyntaxHighlighter.tokenize("end */", language: .swift, inBlockComment: &block)
        #expect(!block)
    }

    @Test("maps extensions and fence labels to languages")
    func languageMapping() {
        #expect(SyntaxHighlighter.Language.named("swift") == .swift)
        #expect(SyntaxHighlighter.Language.named("TS") == .typescript)
        #expect(SyntaxHighlighter.Language.named("bash") == .shell)
        // An unknown label still colours strings and numbers rather than failing.
        #expect(SyntaxHighlighter.Language.named("brainfuck") == .plain)
        #expect(SyntaxHighlighter.Language.named(nil) == .plain)
    }

    @Test("reassembles the original line exactly")
    func losslessTokens() {
        let line = #"func greet(name: String) -> String { "hi \(name)" } // done"#
        #expect(tokens(line, .swift).map(\.text).joined() == line)
    }
}


/// Regressions for the two prompt symptoms the user reported.
///
/// (1) A prompt sent from ANOTHER client never appears here.
/// (2) A prompt sent from THIS app stays pinned as an echo even after processing starts.
struct PromptVisibilityTests {
    private func user(_ id: String, _ text: String) -> TranscriptBlock {
        .user(.init(id: id, timestamp: nil, text: text, truncated: false, images: []))
    }

    private func response(_ blocks: [(String, String)]) throws -> TranscriptResponse {
        let items = blocks.map { #"{"id":"\#($0.0)","kind":"user","text":"\#($0.1)"}"# }.joined(separator: ",")
        return try JSONDecoder().decode(
            TranscriptResponse.self,
            from: Data(#"{"available":true,"blocks":[\#(items)]}"#.utf8)
        )
    }

    // ⚠️ A poll reads a WINDOW of the transcript's end, and that window slides forward. A block
    // present in one poll can be absent from the next without having been deleted — so the parser
    // must accumulate. Replacing the held list with each response is what makes an older prompt
    // vanish from the middle of a live conversation.
    @Test("a prompt that scrolls out of the poll window stays on screen")
    func windowSlideKeepsOlderPrompts() async throws {
        let parser = TranscriptParser()
        await parser.ingest(try response([("u1", "first prompt"), ("u2", "second prompt")]))
        // The next poll's window has moved past u1.
        let snapshot = await parser.ingest(try response([("u2", "second prompt"), ("u3", "third prompt")]))

        #expect(snapshot.blocks.map(\.id) == ["u1", "u2", "u3"])
    }

    // The echo must clear the moment the real entry lands, whatever else is in the window.
    @Test("an echo resolves against the real entry once it appears")
    func echoResolvesWhenRealEntryLands() {
        let pending = TranscriptFeed.PendingSend(text: "ship the fix")
        let before = TranscriptEcho.merge(server: [user("a1", "working on it")], pending: [pending])
        #expect(before.stillPending.count == 1, "no real entry yet, so the echo stays")

        let after = TranscriptEcho.merge(
            server: [user("a1", "working on it"), user("u9", "ship the fix")],
            pending: before.stillPending
        )
        #expect(after.stillPending.isEmpty, "the echo must clear once the real entry arrives")
        #expect(after.blocks.count == 2, "and must not leave a duplicate behind")
    }

    // Smart quotes and trailing newlines survive the round trip through the CLI, so matching has
    // to be resilient to the whitespace the transport adds.
    @Test("matching survives the whitespace a send adds")
    func matchingIsWhitespaceInsensitive() {
        let pending = TranscriptFeed.PendingSend(text: "Let’s dig deeper")
        let merged = TranscriptEcho.merge(server: [user("u1", "Let’s dig deeper\n")], pending: [pending])
        #expect(merged.stillPending.isEmpty)
    }
}


/// When the slash-command picker shows.
///
/// ⚠️ The trigger rule is the whole feature. Too eager and every file path in a conversation pops
/// a list over the composer; too strict and the feature never appears.
struct SlashCommandTriggerTests {
    @Test("triggers on a leading slash and reports the query")
    func triggersOnLeadingSlash() {
        #expect(SlashCommandTrigger.query(in: "/") == "")
        #expect(SlashCommandTrigger.query(in: "/mod") == "mod")
    }

    // A slash appears in every path an agent conversation mentions.
    @Test("ignores a slash that is not the first character")
    func ignoresMidTextSlashes() {
        #expect(SlashCommandTrigger.query(in: "look at src/web/routes") == nil)
        #expect(SlashCommandTrigger.query(in: " /model") == nil)
        #expect(SlashCommandTrigger.query(in: "") == nil)
    }

    // `/model opus` is a command WITH AN ARGUMENT — the choice is made, so the list must get out
    // of the way rather than cover the field.
    @Test("hides once an argument is being typed")
    func hidesAfterASpace() {
        #expect(SlashCommandTrigger.query(in: "/model opus") == nil)
        #expect(SlashCommandTrigger.query(in: "/review\nmore") == nil)
    }
}
