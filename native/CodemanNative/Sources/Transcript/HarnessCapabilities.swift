import Foundation

/// What the composer may offer for a given CLI.
///
/// ⚠️ Codeman sets model and permission mode at **spawn time** — `updateCaseModel` writes
/// `settings.local.json`, `buildPermissionArgs` builds launch flags — and there is no endpoint that
/// changes either on a running session. So a live control has to drive the CLI's own in-session
/// affordance, and those differ per harness.
///
/// This table is deliberately conservative: a capability is listed only where the mechanism is
/// known to work for that CLI. Everything else degrades to showing the value read-only, which is
/// still useful and cannot misfire. Guessing a slash command would type garbage into someone's
/// session.
enum HarnessCapabilities {
    /// How a model is chosen mid-session.
    enum ModelControl: Equatable {
        /// `/model <id>` sets it directly, so the app can offer a menu.
        case directCommand(options: [ModelOption])
        /// The CLI reports its model but offers no one-shot switch; show it and nothing more.
        case readOnly
    }

    struct ModelOption: Equatable, Identifiable, Sendable {
        /// What the user picks, e.g. "Opus".
        var label: String
        /// What is sent after `/model`, e.g. "opus".
        var argument: String
        var id: String { argument }
    }

    /// Claude Code accepts `/model <alias>` as a one-shot. The aliases are the stable ones the CLI
    /// documents; a concrete id typed by the user still works through the terminal.
    private static let claudeModels: [ModelOption] = [
        .init(label: "Opus", argument: "opus"),
        .init(label: "Sonnet", argument: "sonnet"),
        .init(label: "Haiku", argument: "haiku"),
        .init(label: "Default", argument: "default"),
    ]

    static func modelControl(for mode: SessionMode?) -> ModelControl? {
        switch mode {
        case .claude: return .directCommand(options: claudeModels)
        // Codex, OpenCode, Gemini, Antigravity and Pi all report a model, and all of them present
        // `/model` as an interactive picker rather than a one-shot — sending it would leave a
        // half-open menu in the pane with no way to finish from here.
        case .codex, .opencode, .gemini, .antigravity, .pi: return .readOnly
        case .shell, .none: return nil
        @unknown default: return nil
        }
    }

    /// Whether the composer may cycle the CLI's permission mode.
    ///
    /// Claude Code cycles normal → accept-edits → plan on Shift+Tab, which the app can send as the
    /// back-tab sequence over the terminal socket — the same bytes the user's own keyboard sends.
    /// No other supported CLI has an equivalent, so the control is hidden for them rather than
    /// wired to something that does nothing.
    static func supportsPermissionCycling(_ mode: SessionMode?) -> Bool {
        mode == .claude
    }

    /// CSI Z — Shift+Tab. What a hardware keyboard emits, so the CLI cannot tell the difference.
    static let backTabSequence = "\u{1B}[Z"
}

/// Claude Code's permission mode, read off the pane.
///
/// ⚠️ Parsed from the rendered frame because nothing else reports it: `SessionSnapshot` carries the
/// model and effort but not the permission mode, and Codeman has no endpoint for it. The footer
/// line the CLI draws is the only source. Parsing is therefore best-effort by design — an
/// unrecognised footer yields `nil` and the control falls back to a neutral label rather than
/// asserting a mode it does not know.
enum PermissionModeReader {
    enum Mode: String, Equatable, Sendable {
        case normal
        case acceptEdits
        case plan
        case bypass

        var label: String {
            switch self {
            case .normal: return "Ask"
            case .acceptEdits: return "Accept edits"
            case .plan: return "Plan"
            case .bypass: return "Bypass"
            }
        }

        var symbolName: String {
            switch self {
            case .normal: return "hand.raised"
            case .acceptEdits: return "chevron.left.forwardslash.chevron.right"
            case .plan: return "list.bullet.clipboard"
            case .bypass: return "bolt"
            }
        }
    }

    /// Find the mode in a terminal capture.
    ///
    /// Scans from the END: the footer is redrawn at the bottom of the pane, and an older frame
    /// higher in the buffer would report a mode that has since changed.
    static func parse(_ capture: String) -> Mode? {
        let plain = stripANSI(capture).lowercased()
        for line in plain.components(separatedBy: "\n").reversed() {
            guard line.contains(" on") || line.contains("mode") else { continue }
            if line.contains("bypass permissions on") || line.contains("bypassing permissions") { return .bypass }
            if line.contains("plan mode on") { return .plan }
            if line.contains("accept edits on") || line.contains("auto-accept edits on") { return .acceptEdits }
        }
        return nil
    }

    /// Strip CSI/OSC sequences so the footer's colouring does not break the match.
    static func stripANSI(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            guard character == "\u{1B}" else {
                out.append(character)
                continue
            }
            guard let next = iterator.next() else { break }
            if next == "[" {
                // CSI: parameters then a final byte in @–~.
                while let scan = iterator.next() {
                    if scan.isLetter || scan == "@" || scan == "~" { break }
                }
            } else if next == "]" {
                // OSC: runs to BEL or ST.
                while let scan = iterator.next() {
                    if scan == "\u{07}" { break }
                    if scan == "\u{1B}" {
                        pending = iterator.next()
                        break
                    }
                }
            }
        }
        return out
    }
}
