import Foundation
import OSLog

/// Centralised `OSLog` loggers.
///
/// Privacy discipline for this app: anything that could identify the user's machine, workspace,
/// prompt text, or credentials is interpolated with `privacy: .private`. Only enum-like values
/// (HTTP status codes, WebSocket close codes, SSE event names, byte counts) are `.public`.
/// A credential is never handed to a `Logger` in any privacy mode.
enum Log {
    private static let subsystem = "cloud.creature.codeman.native"

    static let net = Logger(subsystem: subsystem, category: "net")
    static let sse = Logger(subsystem: subsystem, category: "sse")
    static let ws = Logger(subsystem: subsystem, category: "ws")
    static let terminal = Logger(subsystem: subsystem, category: "terminal")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let store = Logger(subsystem: subsystem, category: "store")
}
