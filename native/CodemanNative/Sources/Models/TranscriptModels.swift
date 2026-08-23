import Foundation

/// A single rendered unit of a session's conversation.
///
/// Mirrors the server's `TranscriptBlock` union (`src/transcript-blocks.ts`), which reads Claude
/// Code's JSONL transcript. It is a Swift `enum` rather than a struct with optionals because the
/// five shapes share almost nothing: a diff has two sides, a tool call has a result that may not
/// have arrived, and prose has neither. Optionals would push that discrimination into every view.
///
/// ⚠️ Decoding is **lenient by design**. The transcript format belongs to Claude Code, not to
/// Codeman, and a block kind this build has never seen must not fail the whole response — one
/// unknown block would blank the entire view. `TranscriptResponse` drops what it cannot read.
enum TranscriptBlock: Identifiable, Sendable, Hashable {
    case user(UserBlock)
    case thinking(ThinkingBlock)
    case assistant(AssistantBlock)
    case toolCall(ToolCallBlock)
    case diff(DiffBlock)

    struct UserBlock: Sendable, Hashable {
        var id: String
        var timestamp: Date?
        var text: String
        var truncated: Bool
        /// Images are reported as a count; the server never sends their base64 payload.
        var imageCount: Int
    }

    struct ThinkingBlock: Sendable, Hashable {
        var id: String
        var timestamp: Date?
        var text: String
        var truncated: Bool
    }

    struct AssistantBlock: Sendable, Hashable {
        var id: String
        var timestamp: Date?
        var text: String
        var truncated: Bool
    }

    struct ToolCallBlock: Sendable, Hashable {
        var id: String
        var timestamp: Date?
        /// Raw tool name, e.g. `Bash`, `Read`, `mcp__gortex__search`.
        var name: String
        /// One-line gist of the invocation, so a collapsed row still says something.
        var summary: String?
        var input: String?
        var inputTruncated: Bool
        /// `nil` while the call is still running — the result row has not been written yet.
        var result: String?
        var resultTruncated: Bool
        var resultLength: Int?
        var isError: Bool

        var isRunning: Bool { result == nil && !isError }
    }

    struct DiffBlock: Sendable, Hashable {
        var id: String
        var timestamp: Date?
        var name: String
        var filePath: String?
        /// `nil` for a whole-file write, which has no prior content in the transcript.
        var oldText: String?
        var newText: String?
        var oldTruncated: Bool
        var newTruncated: Bool
        var isError: Bool
        var result: String?

        /// Last path component, for a header that has to fit a phone.
        var fileName: String? {
            guard let filePath else { return nil }
            return (filePath as NSString).lastPathComponent
        }
    }

    var id: String {
        switch self {
        case .user(let b): return b.id
        case .thinking(let b): return b.id
        case .assistant(let b): return b.id
        case .toolCall(let b): return b.id
        case .diff(let b): return b.id
        }
    }

    var timestamp: Date? {
        switch self {
        case .user(let b): return b.timestamp
        case .thinking(let b): return b.timestamp
        case .assistant(let b): return b.timestamp
        case .toolCall(let b): return b.timestamp
        case .diff(let b): return b.timestamp
        }
    }
}

// MARK: - Decoding

/// `try?` over `decodeIfPresent` yields a double optional, and flattening that at every call site
/// is both noisy and easy to get subtly wrong. These collapse "absent, null, or wrong type" into
/// one defaulted value — which is the behaviour every field below wants.
private extension KeyedDecodingContainer {
    func flag(_ key: Key) -> Bool { ((try? decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? false }
    func string(_ key: Key) -> String? { (try? decodeIfPresent(String.self, forKey: key)) ?? nil }
    func text(_ key: Key) -> String { string(key) ?? "" }
    func int(_ key: Key) -> Int? { (try? decodeIfPresent(Int.self, forKey: key)) ?? nil }
}

extension TranscriptBlock: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, timestamp, text, truncated, imageCount
        case name, summary, input, inputTruncated, result, resultTruncated, resultLength, isError
        case filePath, oldText, newText, oldTruncated, newTruncated
    }

    /// Thrown for a `kind` this build does not know; `TranscriptResponse` catches it and skips
    /// the block rather than failing the response.
    struct UnknownKind: Error { let kind: String }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let kind = try c.decode(String.self, forKey: .kind)
        // ISO-8601 with fractional seconds, as Claude writes it. A malformed or missing stamp is
        // cosmetic — it only drives a relative-time label — so it degrades to nil.
        let timestamp = c.string(.timestamp).flatMap(TranscriptDateParser.parse)
        let truncated = c.flag(.truncated)

        switch kind {
        case "user":
            self = .user(.init(
                id: id,
                timestamp: timestamp,
                text: c.text(.text),
                truncated: truncated,
                imageCount: c.int(.imageCount) ?? 0
            ))
        case "thinking":
            self = .thinking(.init(
                id: id,
                timestamp: timestamp,
                text: try c.decode(String.self, forKey: .text),
                truncated: truncated
            ))
        case "assistant":
            self = .assistant(.init(
                id: id,
                timestamp: timestamp,
                text: try c.decode(String.self, forKey: .text),
                truncated: truncated
            ))
        case "toolCall":
            self = .toolCall(.init(
                id: id,
                timestamp: timestamp,
                name: try c.decode(String.self, forKey: .name),
                summary: c.string(.summary),
                input: c.string(.input),
                inputTruncated: c.flag(.inputTruncated),
                result: c.string(.result),
                resultTruncated: c.flag(.resultTruncated),
                resultLength: c.int(.resultLength),
                isError: c.flag(.isError)
            ))
        case "diff":
            self = .diff(.init(
                id: id,
                timestamp: timestamp,
                name: try c.decode(String.self, forKey: .name),
                filePath: c.string(.filePath),
                oldText: c.string(.oldText),
                newText: c.string(.newText),
                oldTruncated: c.flag(.oldTruncated),
                newTruncated: c.flag(.newTruncated),
                isError: c.flag(.isError),
                result: c.string(.result)
            ))
        default:
            throw UnknownKind(kind: kind)
        }
    }
}

/// Shared ISO-8601 parsing.
///
/// ⚠️ `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: decoding happens off the main
/// actor (inside `TranscriptParser`), and the class formatter is a reference type that is not
/// `Sendable`, so a shared static of one does not compile under strict concurrency. The format
/// style is a value type, so one shared copy is safe — and a transcript decodes hundreds of
/// stamps per fetch, which is too many to build a formatter for each time.
///
/// Claude writes fractional seconds; the plain style is the fallback for anything that does not.
enum TranscriptDateParser {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func parse(_ raw: String) -> Date? {
        (try? withFraction.parse(raw)) ?? (try? plain.parse(raw))
    }
}

/// Response of `GET /api/sessions/:id/transcript`.
struct TranscriptResponse: Decodable, Sendable {
    /// `false` for a session type that writes no Claude transcript — shell, codex, opencode and
    /// friends. Not an error: those sessions work fine, they just have nothing to show here.
    var available: Bool
    var reason: String?
    var blocks: [TranscriptBlock]
    /// True when older blocks were dropped to satisfy `limit`.
    var truncated: Bool
    var totalBlocks: Int?

    private enum CodingKeys: String, CodingKey {
        case available, reason, blocks, truncated, totalBlocks
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = c.flag(.available)
        reason = c.string(.reason)
        truncated = c.flag(.truncated)
        totalBlocks = c.int(.totalBlocks)

        // ⚠️ Decode block-by-block so one unreadable entry costs one block, not the view. A
        // straight `[TranscriptBlock]` decode throws on the first unknown `kind` and the user
        // gets an empty screen for a conversation that is 99% readable.
        var list: [TranscriptBlock] = []
        if var array = try? c.nestedUnkeyedContainer(forKey: .blocks) {
            while !array.isAtEnd {
                if let block = try? array.decode(TranscriptBlock.self) {
                    list.append(block)
                } else {
                    // The element must still be consumed or the loop never advances.
                    _ = try? array.decode(AnySkipped.self)
                }
            }
        }
        blocks = list
    }

    /// Consumes exactly one element of unknown shape so an undecodable block can be skipped.
    private struct AnySkipped: Decodable {
        init(from decoder: any Decoder) throws {
            _ = try decoder.singleValueContainer()
        }
    }
}
