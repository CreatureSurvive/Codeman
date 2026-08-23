import Foundation

/// Frames on `GET /ws/sessions/:id/terminal`.
///
/// All frames are **JSON text**. There is no binary framing on this channel, but
/// `URLSessionWebSocketTask` may surface a text frame as either `.string` or `.data`, so the
/// receive path decodes both.
enum TerminalServerFrame: Sendable, Equatable {
    /// `{"t":"o","d":"…"}` — terminal output, micro-batched at 8 ms / 16 KiB and wrapped in DEC
    /// 2026 synchronised-update markers by the server.
    case output(String)
    /// `{"t":"c"}` — clear the terminal.
    case clear
    /// `{"t":"r"}` — the buffer is stale; re-pull an authoritative snapshot.
    case needsRefresh
    /// `{"t":"ia","seq":N}` — the server applied (or deduped) input `N`.
    case inputAck(Int)

    static func decode(_ text: String) -> TerminalServerFrame? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["t"] as? String
        else { return nil }

        switch kind {
        case "o":
            guard let payload = object["d"] as? String else { return nil }
            return .output(payload)
        case "c": return .clear
        case "r": return .needsRefresh
        case "ia":
            guard let seq = object["seq"] as? Int else { return nil }
            return .inputAck(seq)
        default: return nil
        }
    }
}

/// Frames the client sends.
enum TerminalClientFrame: Sendable, Equatable {
    /// `{"t":"i","d":…,"seq":N,"cid":…}` — input. `(cid, seq)` is applied at-most-once server-side
    /// and ACKed regardless, so a redelivery after a half-open socket cannot double-type.
    case input(text: String, seq: Int, clientID: String)
    /// `{"t":"z","c":cols,"r":rows,"v":class,"f":force}` — resize.
    case resize(cols: Int, rows: Int, viewport: String?, force: Bool)

    func encoded() -> String? {
        switch self {
        case let .input(text, seq, clientID):
            return Self.serialize(["t": "i", "d": text, "seq": seq, "cid": clientID])
        case let .resize(cols, rows, viewport, force):
            var object: [String: Any] = ["t": "z", "c": cols, "r": rows, "f": force]
            if let viewport { object["v"] = viewport }
            return Self.serialize(object)
        }
    }

    private static func serialize(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Why a terminal socket ended, in the vocabulary the UI needs.
enum TerminalDisconnectReason: Sendable, Equatable {
    case forbidden
    case sessionNotFound
    case tooManyConnections
    case sessionTerminated
    case supersededByReconnect
    case transport(String)
    case normal

    init(closeCode: URLSessionWebSocketTask.CloseCode, rawCode: Int?) {
        switch rawCode {
        case 4003: self = .forbidden
        case 4004: self = .sessionNotFound
        case 4008: self = .tooManyConnections
        case 4009: self = .sessionTerminated
        case 4010: self = .supersededByReconnect
        default:
            self = closeCode == .normalClosure ? .normal : .transport("WebSocket closed (\(rawCode ?? closeCode.rawValue))")
        }
    }

    /// A reconnect is pointless for these: retrying would burn the per-session slot cap or spin
    /// against a session that no longer exists.
    var isTerminal: Bool {
        switch self {
        case .forbidden, .sessionNotFound, .sessionTerminated: true
        case .tooManyConnections, .supersededByReconnect, .transport, .normal: false
        }
    }

    var userMessage: String {
        switch self {
        case .forbidden: "This server refused the terminal connection."
        case .sessionNotFound: "The session no longer exists on the server."
        case .tooManyConnections: "This session already has the maximum of 5 live terminal views."
        case .sessionTerminated: "The session ended."
        case .supersededByReconnect: "Reconnecting…"
        case let .transport(detail): detail
        case .normal: "Disconnected."
        }
    }
}

/// Events a `TerminalTransport` emits. Each carries the **generation** of the socket it came
/// from, which is what makes stale-frame rejection possible without inspecting the payload.
enum TerminalTransportEvent: Sendable {
    case connected(generation: UInt64)
    case frame(TerminalServerFrame, generation: UInt64)
    case disconnected(TerminalDisconnectReason, generation: UInt64)
    case reconnecting(attempt: Int, after: Duration)
}

protocol TerminalTransporting: Sendable {
    func connect(sessionID: String, scope: NodeScope) async -> AsyncStream<TerminalTransportEvent>
    func send(_ frame: TerminalClientFrame) async
    /// Enqueues text as an input frame, assigning the next sequence number.
    func sendInput(_ text: String) async
    func disconnect() async
    func currentGeneration() async -> UInt64
}

/// One terminal WebSocket, with a single actor-owned send pipeline and generation tracking.
///
/// **Ordering contract** (Architecture §4.2–4.3):
///  - received output bytes are forwarded verbatim, in receive order, never parsed or trimmed;
///  - every outbound write — typed keys, accessory keys, paste, programmatic sends — passes
///    through `send`, so there is exactly one writer per socket;
///  - each event carries the generation of the socket that produced it, and the consumer drops
///    anything from a superseded generation.
actor TerminalTransport: TerminalTransporting {
    private let server: ServerConfiguration
    private let credentials: any CredentialStoring
    private let session: URLSession
    /// Stable per (device install, session) id. `WsConnectionRegistry` supersedes only the *same*
    /// `cid`, so a stable value means a reconnect reclaims its own slot instead of consuming a
    /// new one — without it a flaky link burns through the cap of 5 and starts getting `4008`.
    private let clientID: String

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var continuation: AsyncStream<TerminalTransportEvent>.Continuation?
    private var liveStream: AsyncStream<TerminalTransportEvent>?

    private var outbound: AsyncStream<TerminalClientFrame>.Continuation?
    private var generation: UInt64 = 0
    private var sessionID: String = ""
    private var scope: NodeScope = .local
    private var nextSeq: Int = 0
    private var isStopping = false

    init(server: ServerConfiguration, credentials: any CredentialStoring, session: URLSession, clientID: String) {
        self.server = server
        self.credentials = credentials
        self.session = session
        self.clientID = clientID
    }

    func currentGeneration() async -> UInt64 { generation }

    func connect(sessionID: String, scope: NodeScope) async -> AsyncStream<TerminalTransportEvent> {
        await disconnect()

        self.sessionID = sessionID
        self.scope = scope
        isStopping = false

        let (stream, continuation) = AsyncStream<TerminalTransportEvent>.makeStream(bufferingPolicy: .bufferingNewest(2048))
        self.continuation = continuation
        liveStream = stream

        receiveTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
        return stream
    }

    func disconnect() async {
        isStopping = true
        receiveTask?.cancel()
        receiveTask = nil
        sendTask?.cancel()
        sendTask = nil
        outbound?.finish()
        outbound = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        continuation?.finish()
        continuation = nil
        liveStream = nil
    }

    func send(_ frame: TerminalClientFrame) async {
        outbound?.yield(frame)
    }

    func sendInput(_ text: String) async {
        guard !text.isEmpty else { return }
        let seq = nextSeq
        nextSeq += 1
        await send(.input(text: text, seq: seq, clientID: clientID))
    }

    // MARK: - Connection loop

    private func emit(_ event: TerminalTransportEvent) {
        continuation?.yield(event)
    }

    private func runConnectionLoop() async {
        var backoff = Backoff(initial: .milliseconds(400), maximum: .seconds(20))

        while !Task.isCancelled && !isStopping {
            let reason: TerminalDisconnectReason
            do {
                reason = try await runOneConnection()
            } catch is CancellationError {
                return
            } catch let error as APIError {
                if error.isUnauthorized {
                    emit(.disconnected(.forbidden, generation: generation))
                    return
                }
                reason = .transport(error.localizedDescription)
            } catch {
                reason = .transport(error.localizedDescription)
            }

            emit(.disconnected(reason, generation: generation))
            guard !reason.isTerminal, !Task.isCancelled, !isStopping else { return }

            let delay = backoff.next()
            emit(.reconnecting(attempt: backoff.attempt, after: delay))
            Log.ws.info("Terminal reconnect \(backoff.attempt, privacy: .public) in \(delay.seconds, privacy: .public)s")
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }

    /// Opens one socket and pumps it until it closes. Returns why it closed.
    private func runOneConnection() async throws -> TerminalDisconnectReason {
        // A new socket is a new epoch: everything from the previous one is stale from here on.
        generation &+= 1
        let myGeneration = generation

        guard let base = server.baseURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw APIError.badURL }

        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.path += scope.terminalSocketPath(sessionID: sessionID)
        components.queryItems = [URLQueryItem(name: "cid", value: clientID)]
        guard let url = components.url else { throw APIError.badURL }

        var request = URLRequest(url: url)
        // `Authorization` is settable on a WebSocket upgrade (it is not a reserved header) and is
        // what carries auth through the global `onRequest` hook that runs on the handshake.
        // `Origin` is deliberately absent — a missing Origin is the allowed case in the CSWSH
        // guard, and supplying one could only fail (API-Audit §3.3).
        if let header = await credentials.credential(for: server.id).authorizationHeader {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }

        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()

        // One writer per socket, fed by a single stream — this is the serialization point.
        let (frames, outboundContinuation) = AsyncStream<TerminalClientFrame>.makeStream(bufferingPolicy: .unbounded)
        outbound = outboundContinuation
        sendTask = Task { [weak self] in
            for await frame in frames {
                guard let self else { return }
                await self.write(frame, on: task)
            }
        }

        emit(.connected(generation: myGeneration))
        Log.ws.info("Terminal socket open (generation \(myGeneration, privacy: .public))")

        defer {
            outboundContinuation.finish()
            sendTask?.cancel()
            sendTask = nil
        }

        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if let closeCode = socket?.closeCode, closeCode != .invalid {
                    return TerminalDisconnectReason(closeCode: closeCode, rawCode: closeCode.rawValue)
                }
                if Task.isCancelled || isStopping { throw CancellationError() }
                return .transport(error.localizedDescription)
            }

            // The channel is JSON text, but URLSession can surface it either way.
            let text: String?
            switch message {
            case let .string(value): text = value
            case let .data(value): text = String(data: value, encoding: .utf8)
            @unknown default: text = nil
            }

            guard let text, let frame = TerminalServerFrame.decode(text) else { continue }
            emit(.frame(frame, generation: myGeneration))
        }

        throw CancellationError()
    }

    private func write(_ frame: TerminalClientFrame, on task: URLSessionWebSocketTask) async {
        guard let encoded = frame.encoded() else { return }
        do {
            try await task.send(.string(encoded))
        } catch {
            Log.ws.warning("Terminal send failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
