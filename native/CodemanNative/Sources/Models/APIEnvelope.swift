import Foundation

/// `ApiErrorCode` from `src/types/api.ts`.
///
/// `unknown` exists so a newer server cannot break decoding — the raw string is preserved for
/// display and logging.
enum APIErrorCode: RawRepresentable, Sendable, Hashable {
    case notFound
    case invalidInput
    case unauthorized
    case sessionBusy
    case conflict
    case alreadyExists
    case rateLimited
    case operationFailed
    case forbidden
    case passwordChangeRequired
    case userExists
    case userNotFound
    case lastAdmin
    case internalError
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "NOT_FOUND": self = .notFound
        case "INVALID_INPUT": self = .invalidInput
        case "UNAUTHORIZED": self = .unauthorized
        case "SESSION_BUSY": self = .sessionBusy
        case "CONFLICT": self = .conflict
        case "ALREADY_EXISTS": self = .alreadyExists
        case "RATE_LIMITED": self = .rateLimited
        case "OPERATION_FAILED": self = .operationFailed
        case "FORBIDDEN": self = .forbidden
        case "PASSWORD_CHANGE_REQUIRED": self = .passwordChangeRequired
        case "USER_EXISTS": self = .userExists
        case "USER_NOT_FOUND": self = .userNotFound
        case "LAST_ADMIN": self = .lastAdmin
        case "INTERNAL_ERROR": self = .internalError
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .notFound: "NOT_FOUND"
        case .invalidInput: "INVALID_INPUT"
        case .unauthorized: "UNAUTHORIZED"
        case .sessionBusy: "SESSION_BUSY"
        case .conflict: "CONFLICT"
        case .alreadyExists: "ALREADY_EXISTS"
        case .rateLimited: "RATE_LIMITED"
        case .operationFailed: "OPERATION_FAILED"
        case .forbidden: "FORBIDDEN"
        case .passwordChangeRequired: "PASSWORD_CHANGE_REQUIRED"
        case .userExists: "USER_EXISTS"
        case .userNotFound: "USER_NOT_FOUND"
        case .lastAdmin: "LAST_ADMIN"
        case .internalError: "INTERNAL_ERROR"
        case let .unknown(raw): raw
        }
    }
}

extension APIErrorCode: Codable {
    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Every failure the client can surface. Carries both the HTTP status and the server's own
/// `errorCode`, because callers legitimately branch on the difference (see Architecture §3.1).
enum APIError: Error, Sendable {
    /// A structured `{success:false, error, errorCode}` envelope.
    case server(status: Int, code: APIErrorCode, message: String)
    /// A non-2xx response whose body was not a Codeman error envelope.
    case http(status: Int, body: String)
    /// Rate limited; `retryAfter` is the parsed `Retry-After` header, when present.
    case rateLimited(retryAfter: TimeInterval?)
    /// The response body could not be decoded into the expected shape.
    case decoding(String)
    /// Transport-level failure (offline, TLS, timeout…).
    case transport(URLError)
    /// The active server has no stored credentials and the endpoint needs them.
    case notAuthenticated
    /// The URL could not be constructed from the configured base.
    case badURL

    var isUnauthorized: Bool {
        switch self {
        case let .server(status, code, _): status == 401 || code == .unauthorized
        case let .http(status, _): status == 401
        default: false
        }
    }

    /// The route itself does not exist on this server, as opposed to the *resource* being missing.
    ///
    /// ⚠️ Both are 404 with `errorCode: NOT_FOUND`, and the difference matters to the user: a
    /// missing session is "that's gone", a missing route is "this Codeman is older than this app".
    /// Fastify's not-found body is what separates them — it reads `Route GET:/api/... not found`,
    /// whereas a handler's own 404 describes the resource. Matching that prefix is the only signal
    /// the wire actually carries.
    var isMissingEndpoint: Bool {
        switch self {
        case let .server(status, _, message): status == 404 && message.hasPrefix("Route ")
        case let .http(status, body): status == 404 && body.contains("Route ")
        default: false
        }
    }

    var isForbidden: Bool {
        switch self {
        case let .server(status, code, _): status == 403 || code == .forbidden
        case let .http(status, _): status == 403
        default: false
        }
    }
}

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .server(_, _, message):
            // The server writes better messages than we could — a missing CLI comes back with the
            // exact install command. Surface it verbatim.
            message
        case let .http(status, body):
            body.isEmpty ? "Server returned HTTP \(status)." : body
        case let .rateLimited(retryAfter):
            if let retryAfter {
                "Too many attempts. Try again in \(Int(retryAfter.rounded())) seconds."
            } else {
                "Too many attempts. Try again shortly."
            }
        case let .decoding(detail):
            "The server sent a response this app could not read. \(detail)"
        case let .transport(error):
            error.localizedDescription
        case .notAuthenticated:
            "This server needs a username and password."
        case .badURL:
            "The server address is not a valid URL."
        }
    }
}

/// The `{success:false, error, errorCode}` half of the envelope.
struct APIErrorEnvelope: Decodable, Sendable {
    let success: Bool
    let error: String
    let errorCode: APIErrorCode
}

/// Decodes the three response shapes the server actually emits (API-Audit §1.1):
///
/// 1. `{"success":true,"data":<T>}` — the `preSerialization` hook's wrap, and the shape
///    hand-built by handlers that return `{success:true,data}` themselves.
/// 2. `{"success":false,"error":…,"errorCode":…}` — an error envelope.
/// 3. a bare `<T>` — raw routes (buffers, streams) and any body the hook passed through.
///
/// Case 3 matters more than it looks: `GET /api/sessions` returns a bare array which the hook
/// *does* wrap, but `GET /api/away-digest` hand-builds `{success:true,digest}` with no `data`
/// key at all, and `204` bodies are empty.
enum APIEnvelope {
    /// `{success:true,data:T}` with a fallback to a bare `T`.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, decoder: JSONDecoder) throws -> T {
        if data.isEmpty {
            if let empty = EmptyResponse() as? T { return empty }
            throw APIError.decoding("Empty response body where \(T.self) was expected.")
        }

        // Try the wrapped shape first — it is the common case.
        if let wrapper = try? decoder.decode(SuccessEnvelope<T>.self, from: data), wrapper.success {
            if let value = wrapper.data { return value }
            // `{"success":true}` with no data: valid for endpoints that return nothing.
            if let empty = EmptyResponse() as? T { return empty }
        }

        // An explicit error envelope.
        if let failure = try? decoder.decode(APIErrorEnvelope.self, from: data), failure.success == false {
            throw APIError.server(status: 200, code: failure.errorCode, message: failure.error)
        }

        // Bare payload.
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Reads an error envelope out of a non-2xx body, falling back to the raw text.
    static func decodeFailure(status: Int, data: Data, decoder: JSONDecoder) -> APIError {
        if let failure = try? decoder.decode(APIErrorEnvelope.self, from: data), failure.success == false {
            return .server(status: status, code: failure.errorCode, message: failure.error)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        return .http(status: status, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private struct SuccessEnvelope<T: Decodable>: Decodable {
        let success: Bool
        let data: T?
    }
}

/// Stand-in for endpoints that return nothing meaningful (`{}`, `204`).
struct EmptyResponse: Codable, Sendable, Equatable {
    init() {}
    init(from _: any Decoder) throws {}
    func encode(to encoder: any Encoder) throws {
        _ = encoder.container(keyedBy: CodingKeys.self)
    }

    private enum CodingKeys: CodingKey {}
}
