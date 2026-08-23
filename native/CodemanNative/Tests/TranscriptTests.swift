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
          {"id":"1","kind":"user","text":"hello","imageCount":2},
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
        #expect(u.imageCount == 2)

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
