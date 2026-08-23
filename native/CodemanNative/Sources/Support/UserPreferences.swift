import Foundation
import GhosttyTerminal
import SwiftUI
import UIKit

/// How a session pane presents itself.
///
/// The terminal is the live agent surface — it accepts keystrokes and shows exactly what the CLI
/// painted. The transcript is a native read view of the same conversation: structured, selectable,
/// and legible at a phone's font size. Both read the same session; neither replaces the other.
enum SessionViewMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case terminal
    case transcript

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .transcript: return "Chat"
        }
    }

    var symbolName: String {
        switch self {
        case .terminal: return "terminal"
        case .transcript: return "text.bubble"
        }
    }
}

/// Per-device preferences.
///
/// The web client splits settings into *server-synced* and *per-device by client policy*. This
/// app keeps the same split: anything the web client treats as a display key stays local, and
/// anything in `SettingsUpdateSchema` that genuinely describes shared behaviour (custom actions,
/// run mode) goes to the server.
///
/// Terminal appearance is device-local by nature — the web client's xterm palette has no native
/// analogue, and a font size that suits a 6.1" phone is wrong on a 13" iPad.
struct UserPreferences: Sendable, Codable, Equatable {
    var terminalFontSize: Double = 13
    var terminalTheme: CodemanTerminalTheme = .systemAdaptive
    /// Extra accessory keys the user pinned, rendered as `.symbol` items after the fixed set.
    var accessoryShortcuts: [String] = ["/", "|", "-", "~"]
    var showInspector: Bool = true
    var confirmBeforeDeletingSessions: Bool = true
    var notificationsEnabled: Bool = true

    /// The `viewportType` sent with a resize. Derived from the *pane's* environment rather than
    /// the device: a split pane on iPad is not a desktop viewport, and the server uses this to
    /// decide whether a desktop is holding a sizing claim.
    var viewportClass: String = "mobile"

    /// Which surface a newly opened session shows. The terminal stays the default: it is the one
    /// that accepts input, and a first-run user landing on a read-only view would look stuck.
    var defaultSessionViewMode: SessionViewMode = .terminal

    /// ⚠️ **Every key is optional on read.**
    ///
    /// Swift's synthesized `Decodable` does not fall back to a property's default value when a key
    /// is missing — it throws. With `load()` catching that and returning `UserPreferences()`, any
    /// *added* property silently reset every other preference the user had set, on the first
    /// launch after an update. Decoding each key independently means an older stored blob keeps
    /// what it has and picks up defaults for what it lacks.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UserPreferences()
        terminalFontSize = try container.decodeIfPresent(Double.self, forKey: .terminalFontSize)
            ?? defaults.terminalFontSize
        terminalTheme = try container.decodeIfPresent(CodemanTerminalTheme.self, forKey: .terminalTheme)
            ?? defaults.terminalTheme
        accessoryShortcuts = try container.decodeIfPresent([String].self, forKey: .accessoryShortcuts)
            ?? defaults.accessoryShortcuts
        showInspector = try container.decodeIfPresent(Bool.self, forKey: .showInspector)
            ?? defaults.showInspector
        confirmBeforeDeletingSessions = try container
            .decodeIfPresent(Bool.self, forKey: .confirmBeforeDeletingSessions)
            ?? defaults.confirmBeforeDeletingSessions
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)
            ?? defaults.notificationsEnabled
        viewportClass = try container.decodeIfPresent(String.self, forKey: .viewportClass)
            ?? defaults.viewportClass
        defaultSessionViewMode = try container
            .decodeIfPresent(SessionViewMode.self, forKey: .defaultSessionViewMode)
            ?? defaults.defaultSessionViewMode
    }

    init() {}

    private static let key = "codeman.native.preferences"

    static func load() -> UserPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(UserPreferences.self, from: data)
        else { return UserPreferences() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// Fixed keys, then the user's pinned shortcuts. Ordered so the destructive-adjacent keys
    /// (Esc, Ctrl) sit at the reachable left edge and the arrow cluster stays contiguous.
    ///
    /// One-shot Ctrl/Alt behaviour comes from the package's own sticky-modifier machinery, so the
    /// app does not reimplement it. `paste` is included because iOS has no keyboard paste key.
    var accessoryItems: [TerminalInputAccessoryItem] {
        var items: [TerminalInputAccessoryItem] = [
            .esc, .tab, .ctrl, .alt,
            .divider,
            .arrowLeft, .arrowUp, .arrowDown, .arrowRight,
        ]
        let shortcuts = accessoryShortcuts.filter { !$0.isEmpty }.prefix(6)
        if !shortcuts.isEmpty {
            items.append(.divider)
            items.append(contentsOf: shortcuts.map { TerminalInputAccessoryItem.symbol($0) })
        }
        items.append(.divider)
        items.append(.paste)
        return items
    }
}

extension CodemanTerminalTheme: Codable {}
