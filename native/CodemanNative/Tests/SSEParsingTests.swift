import Foundation
import Testing
@testable import Codeman

@Suite("SSE parsing")
struct SSEParsingTests {
    private func frames(_ chunks: [String]) -> [SSEFrame] {
        var parser = SSEParser()
        var out: [SSEFrame] = []
        for chunk in chunks { out += parser.consume(Data(chunk.utf8)) }
        return out
    }

    @Test("parses a named event with data")
    func parsesNamedEvent() throws {
        let result = frames(["event: session:created\ndata: {\"id\":\"abc\"}\n\n"])
        #expect(result.count == 1)
        #expect(result[0].name == .known(.sessionCreated))
        #expect(String(decoding: result[0].data, as: UTF8.self) == #"{"id":"abc"}"#)
    }

    /// The server's keepalive had to become a *named* event because SSE comments are invisible to
    /// `EventSource` by spec — a client could not observe a stream that had gone quiet.
    @Test("parses the named heartbeat")
    func parsesHeartbeat() {
        let result = frames(["event: sse:heartbeat\ndata: {\"t\":1}\n\n"])
        #expect(result.count == 1)
        #expect(result[0].name == .known(.heartbeat))
    }

    @Test("joins repeated data lines with a newline")
    func joinsDataLines() {
        let result = frames(["event: x\ndata: one\ndata: two\n\n"])
        #expect(String(decoding: result[0].data, as: UTF8.self) == "one\ntwo")
    }

    @Test("handles CRLF terminators")
    func handlesCRLF() {
        let result = frames(["event: init\r\ndata: {}\r\n\r\n"])
        #expect(result.count == 1)
        #expect(result[0].name == .known(.initial))
    }

    @Test("ignores comment lines")
    func ignoresComments() {
        let result = frames([": keepalive\n\nevent: init\ndata: {}\n\n"])
        #expect(result.count == 1)
        #expect(result[0].name == .known(.initial))
    }

    @Test("captures id and retry")
    func capturesIDAndRetry() {
        let result = frames(["id: 42\nretry: 5000\nevent: init\ndata: {}\n\n"])
        #expect(result[0].id == "42")
        #expect(result[0].retry == 5000)
    }

    /// The whole reason the parser works on bytes rather than `AsyncBytes.lines`: a multi-byte
    /// scalar split across a chunk boundary must not become U+FFFD.
    @Test("survives a UTF-8 scalar split across chunks")
    func splitScalar() {
        let payload = "✻ Actualizing… 汉字"
        let bytes = Array("event: session:terminal\ndata: {\"d\":\"\(payload)\"}\n\n".utf8)

        // Split at every single byte boundary — the worst case for a naive decoder.
        var parser = SSEParser()
        var collected: [SSEFrame] = []
        for byte in bytes {
            collected += parser.consume(Data([byte]))
        }

        #expect(collected.count == 1)
        let text = String(decoding: collected[0].data, as: UTF8.self)
        #expect(text.contains(payload))
        #expect(!text.contains("\u{FFFD}"))
    }

    @Test("delivers multiple frames from one chunk")
    func multipleFramesOneChunk() {
        let result = frames(["event: a\ndata: 1\n\nevent: session:idle\ndata: 2\n\n"])
        #expect(result.count == 2)
        #expect(result[0].name == .unknown("a"))
        #expect(result[1].name == .known(.sessionIdle))
    }

    @Test("holds a partial frame until its blank line arrives")
    func holdsPartialFrame() {
        var parser = SSEParser()
        #expect(parser.consume(Data("event: session:idle\ndata: {}\n".utf8)).isEmpty)
        let done = parser.consume(Data("\n".utf8))
        #expect(done.count == 1)
    }

    @Test("strips exactly one space after the colon")
    func stripsOneSpace() {
        let result = frames(["event: x\ndata:  leading\n\n"])
        #expect(String(decoding: result[0].data, as: UTF8.self) == " leading")
    }

    @Test("an unknown event name decodes rather than throwing")
    func unknownEventName() {
        let result = frames(["event: future:thing\ndata: {}\n\n"])
        #expect(result[0].name == .unknown("future:thing"))
        #expect(result[0].name.known == nil)
    }
}

@Suite("SSE registry parity")
struct SSEEventNameParityTests {
    /// The native registry must match `src/web/sse-events.ts` exactly. The repo's own
    /// `test/sse-registry-parity.test.ts` pins the backend against the web frontend; this is the
    /// third leg, so a server-side addition fails here instead of silently becoming an ignored
    /// event on iOS.
    ///
    /// The TypeScript file is located relative to this source file rather than bundled, so the
    /// check runs against the working tree. When it cannot be found (a build from an exported
    /// archive), the test records that and passes rather than failing for the wrong reason.
    @Test("every backend event name is modelled")
    func parity() throws {
        guard let source = Self.loadRegistrySource() else {
            withKnownIssue("sse-events.ts not reachable from this build; parity not checked") {
                Issue.record("registry source unavailable")
            }
            return
        }

        let backend = Self.extractEventStrings(from: source)
        #expect(backend.count > 150, "parsed only \(backend.count) events — the extractor is wrong")

        let native = Set(SSEEventName.Known.allCases.map(\.rawValue))
        let missing = backend.subtracting(native).sorted()
        let extra = native.subtracting(backend).sorted()

        #expect(missing.isEmpty, "SSEEventName is missing: \(missing.joined(separator: ", "))")
        #expect(extra.isEmpty, "SSEEventName has entries the server does not emit: \(extra.joined(separator: ", "))")
    }

    /// Matches `export const Name = 'value' as const;`.
    static func extractEventStrings(from source: String) -> Set<String> {
        var found: Set<String> = []
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("export const "), trimmed.contains(" as const;") else { continue }
            guard let open = trimmed.firstIndex(of: "'") else { continue }
            let afterOpen = trimmed.index(after: open)
            guard let close = trimmed[afterOpen...].firstIndex(of: "'") else { continue }
            found.insert(String(trimmed[afterOpen..<close]))
        }
        return found
    }

    /// Walks up from this file to the repo root and reads `src/web/sse-events.ts`.
    static func loadRegistrySource(file: StaticString = #filePath) -> String? {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appending(path: "src/web/sse-events.ts")
            if let contents = try? String(contentsOf: candidate, encoding: .utf8) { return contents }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
