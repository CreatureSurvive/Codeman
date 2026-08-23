import Foundation
import Testing
@testable import Codeman

/// The server emits three response shapes through one `preSerialization` hook (API-Audit §1.1),
/// and a client that only handles the common one breaks on the other two.
@Suite("API envelope")
struct EnvelopeTests {
    private let decoder = JSONDecoder()

    struct Payload: Codable, Equatable, Sendable {
        var sessionId: String
        var caseName: String?
    }

    @Test("unwraps { success: true, data }")
    func unwrapsWrapped() throws {
        let json = Data(#"{"success":true,"data":{"sessionId":"abc","caseName":"demo"}}"#.utf8)
        let value = try APIEnvelope.decode(Payload.self, from: json, decoder: decoder)
        #expect(value == Payload(sessionId: "abc", caseName: "demo"))
    }

    /// Handlers that build `{success:true,data}` themselves are passed through by the hook, not
    /// wrapped a second time — so a client must never expect `data.data`.
    @Test("never double-unwraps")
    func neverDoubleUnwraps() throws {
        let json = Data(#"{"success":true,"data":{"sessionId":"abc"}}"#.utf8)
        let value = try APIEnvelope.decode(Payload.self, from: json, decoder: decoder)
        #expect(value.sessionId == "abc")
    }

    /// `GET /api/sessions` returns a bare array and raw routes return unwrapped bodies.
    @Test("accepts a bare payload")
    func acceptsBare() throws {
        let json = Data(#"{"sessionId":"xyz"}"#.utf8)
        let value = try APIEnvelope.decode(Payload.self, from: json, decoder: decoder)
        #expect(value.sessionId == "xyz")
    }

    @Test("accepts a bare array")
    func acceptsBareArray() throws {
        let json = Data(#"[{"sessionId":"one"},{"sessionId":"two"}]"#.utf8)
        let value = try APIEnvelope.decode([Payload].self, from: json, decoder: decoder)
        #expect(value.count == 2)
    }

    @Test("throws the server's message and code on an error envelope")
    func throwsOnErrorEnvelope() {
        let json = Data(#"{"success":false,"error":"Session is busy","errorCode":"SESSION_BUSY"}"#.utf8)
        #expect(throws: APIError.self) {
            _ = try APIEnvelope.decode(Payload.self, from: json, decoder: decoder)
        }

        do {
            _ = try APIEnvelope.decode(Payload.self, from: json, decoder: decoder)
            Issue.record("expected a throw")
        } catch let error as APIError {
            guard case let .server(_, code, message) = error else {
                Issue.record("expected .server, got \(error)")
                return
            }
            #expect(code == .sessionBusy)
            #expect(message == "Session is busy")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// A 204 has no body; decoding must not fail for a void endpoint.
    @Test("decodes an empty body as EmptyResponse")
    func decodesEmptyBody() throws {
        let value = try APIEnvelope.decode(EmptyResponse.self, from: Data(), decoder: decoder)
        #expect(value == EmptyResponse())
    }

    /// `{}` is what most mutating handlers return.
    @Test("decodes {} as EmptyResponse")
    func decodesEmptyObject() throws {
        let value = try APIEnvelope.decode(EmptyResponse.self, from: Data("{}".utf8), decoder: decoder)
        #expect(value == EmptyResponse())
    }

    @Test("maps a non-2xx error envelope, preserving the status")
    func mapsFailureStatus() {
        let json = Data(#"{"success":false,"error":"Node not found","errorCode":"NOT_FOUND"}"#.utf8)
        let error = APIEnvelope.decodeFailure(status: 404, data: json, decoder: decoder)
        guard case let .server(status, code, message) = error else {
            Issue.record("expected .server")
            return
        }
        #expect(status == 404)
        #expect(code == .notFound)
        #expect(message == "Node not found")
    }

    @Test("falls back to raw text when the body is not an envelope")
    func fallsBackToRawBody() {
        let error = APIEnvelope.decodeFailure(status: 403, data: Data("Forbidden: host not allowed".utf8), decoder: decoder)
        guard case let .http(status, body) = error else {
            Issue.record("expected .http")
            return
        }
        #expect(status == 403)
        #expect(body == "Forbidden: host not allowed")
    }

    /// A newer server must not break an older client.
    @Test("preserves an unknown error code")
    func preservesUnknownCode() {
        let code = APIErrorCode(rawValue: "SOME_FUTURE_CODE")
        #expect(code == .unknown("SOME_FUTURE_CODE"))
        #expect(code.rawValue == "SOME_FUTURE_CODE")
    }
}
