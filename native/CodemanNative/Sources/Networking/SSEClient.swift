import Foundation

/// Incremental Server-Sent Events parser.
///
/// Written against the byte stream rather than `URLSession.AsyncBytes.lines` on purpose: a
/// multi-byte UTF-8 character (an agent printing `✻` or a CJK prompt) can straddle a chunk
/// boundary, and a per-chunk `String(decoding:)` would replace the split scalar with U+FFFD.
/// Bytes are accumulated and decoded only at line boundaries, so a partial scalar simply stays
/// in the carry buffer until its tail arrives.
///
/// Implements the parts of the SSE grammar Codeman actually uses: `event:`, `data:` (repeatable,
/// joined with `\n`), `id:`, `retry:`, `:`-leading comments, and blank-line frame termination.
/// Both LF and CRLF terminators are handled.
struct SSEParser: Sendable {
    private var carry = Data()
    private var eventName: String?
    private var dataLines: [String] = []
    private var lastID: String?
    private var retry: Int?

    /// Bytes exceeding this without a newline are dropped — a stream that never terminates a line
    /// is not an SSE stream, and an unbounded carry buffer is a memory hazard on a 24-hour session.
    private static let maxCarryBytes = 4 * 1024 * 1024

    /// Feeds a chunk and returns every complete frame it contained.
    mutating func consume(_ chunk: Data) -> [SSEFrame] {
        carry.append(chunk)
        guard carry.count <= Self.maxCarryBytes else {
            Log.sse.error("SSE carry buffer exceeded \(Self.maxCarryBytes, privacy: .public) bytes; resetting")
            carry.removeAll(keepingCapacity: false)
            reset()
            return []
        }

        var frames: [SSEFrame] = []
        while let newlineIndex = carry.firstIndex(of: 0x0A) {
            let lineBytes = carry[carry.startIndex..<newlineIndex]
            carry.removeSubrange(carry.startIndex...newlineIndex)

            // Strip a trailing CR so CRLF streams parse identically to LF streams.
            var slice = lineBytes
            if slice.last == 0x0D { slice = slice.dropLast() }

            let line = String(decoding: slice, as: UTF8.self)
            if let frame = consume(line: line) { frames.append(frame) }
        }
        return frames
    }

    /// Returns a frame when `line` terminated one.
    private mutating func consume(line: String) -> SSEFrame? {
        if line.isEmpty {
            // Blank line: dispatch. A frame with no `data:` at all is a no-op per spec, but
            // Codeman's heartbeat always carries data and the caller wants liveness either way.
            guard eventName != nil || !dataLines.isEmpty else { return nil }
            let frame = SSEFrame(
                name: SSEEventName(rawValue: eventName ?? "message"),
                data: Data(dataLines.joined(separator: "\n").utf8),
                id: lastID,
                retry: retry
            )
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
            retry = nil
            return frame
        }

        if line.hasPrefix(":") { return nil } // comment — ignored, but the caller still saw bytes

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            // Exactly one leading space after the colon is part of the framing, not the value.
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        case "id":
            // Per spec an id containing NUL is ignored.
            if !value.contains("\u{0}") { lastID = value }
        case "retry": retry = Int(value)
        default: break // unknown field — ignored per spec
        }
        return nil
    }

    mutating func reset() {
        eventName = nil
        dataLines.removeAll(keepingCapacity: false)
        retry = nil
    }

    var lastEventID: String? { lastID }
}

/// What an `EventStream` emits to its consumer.
enum EventStreamSignal: Sendable {
    case connected
    case frame(SSEFrame)
    case reconnecting(attempt: Int, after: Duration, reason: String)
    case failed(APIError)
}

protocol EventStreaming: Sendable {
    /// Starts (or returns the existing) stream. Calling twice never opens two connections.
    func start(scope: NodeScope) async -> AsyncStream<EventStreamSignal>
    func stop() async
}

/// The `GET /api/events` stream.
///
/// Owns exactly one `Task`. `start` is idempotent: a second call while running returns the same
/// stream, which is what stops a foreground/background bounce from duplicating connections.
actor EventStream: EventStreaming {
    private let server: ServerConfiguration
    private let credentials: any CredentialStoring
    private let session: URLSession
    /// Stable per-connection id, so the filter can be changed later via
    /// `POST /api/events/subscribe` without reconnecting. Must match
    /// `/^[A-Za-z0-9_-]{8,64}$/` (`SSE_CLIENT_ID_RE` in server.ts).
    private let clientID: String

    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<EventStreamSignal>.Continuation?
    private var liveStream: AsyncStream<EventStreamSignal>?
    private var lastEventID: String?
    private var currentScope: NodeScope = .local

    init(server: ServerConfiguration, credentials: any CredentialStoring, session: URLSession) {
        self.server = server
        self.credentials = credentials
        self.session = session
        clientID = Self.makeClientID()
    }

    /// 32 hex characters — inside the server's 8…64 length window and its `[A-Za-z0-9_-]` class.
    static func makeClientID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Idempotent: while a stream against the same scope is already running, the existing one is
    /// returned. That is what keeps a background→foreground bounce, or two views both asking for
    /// events, from opening a second connection against the server's 100-client cap.
    func start(scope: NodeScope) async -> AsyncStream<EventStreamSignal> {
        if task != nil, scope == currentScope, let stream = liveStream {
            return stream
        }

        await stop()
        currentScope = scope

        let (stream, continuation) = AsyncStream<EventStreamSignal>.makeStream(bufferingPolicy: .bufferingNewest(512))
        self.continuation = continuation
        liveStream = stream

        task = Task { [weak self] in
            await self?.run()
        }
        return stream
    }

    func stop() async {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
        liveStream = nil
    }

    private func emit(_ signal: EventStreamSignal) {
        continuation?.yield(signal)
    }

    private func run() async {
        var backoff = Backoff()

        while !Task.isCancelled {
            do {
                try await connectOnce()
                // A clean end-of-stream is still a disconnect; fall through to reconnect.
                guard !Task.isCancelled else { return }
                let delay = backoff.next()
                emit(.reconnecting(attempt: backoff.attempt, after: delay, reason: "Stream ended"))
                try await Task.sleep(for: delay)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }

                if let apiError = error as? APIError, apiError.isUnauthorized {
                    // Never retry a 401: the per-IP failure bucket is shared with the login path,
                    // and ten of these lock the whole server out for 15 minutes (API-Audit §2.1).
                    emit(.failed(apiError))
                    return
                }

                let delay = backoff.next()
                let reason = (error as? any LocalizedError)?.errorDescription ?? "\(error)"
                emit(.reconnecting(attempt: backoff.attempt, after: delay, reason: reason))
                Log.sse.warning("SSE reconnect \(backoff.attempt, privacy: .public) in \(delay.seconds, privacy: .public)s")
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    private func connectOnce() async throws {
        guard let base = server.baseURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw APIError.badURL }

        components.path += currentScope.apiPath("/api/events")
        components.queryItems = [URLQueryItem(name: "clientId", value: clientID)]
        guard let url = components.url else { throw APIError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let header = await credentials.credential(for: server.id).authorizationHeader {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        if let lastEventID {
            request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.decoding("SSE response was not HTTP.")
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 503 {
                throw APIError.http(status: 503, body: "Too many SSE connections.")
            }
            throw APIError.http(status: http.statusCode, body: "")
        }

        emit(.connected)
        Log.sse.info("SSE connected (status \(http.statusCode, privacy: .public))")

        var parser = SSEParser()
        // `bytes` yields one UInt8 at a time; batching into a small buffer before parsing keeps
        // the per-byte await out of the hot path during a burst of terminal output.
        var buffer = Data()
        buffer.reserveCapacity(8192)

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if byte == 0x0A || buffer.count >= 8192 {
                for frame in parser.consume(buffer) {
                    if let id = frame.id { lastEventID = id }
                    emit(.frame(frame))
                }
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            for frame in parser.consume(buffer) {
                if let id = frame.id { lastEventID = id }
                emit(.frame(frame))
            }
        }
    }
}
