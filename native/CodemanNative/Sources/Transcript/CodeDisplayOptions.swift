import SwiftUI

/// How code is displayed in the file viewer and tool output.
///
/// Per-device and remembered: someone reading long shell output on a phone wants wrapping, and
/// someone comparing indentation wants it off. Neither is a good permanent default for the other.
@MainActor
@Observable
final class CodeDisplayOptions {
    static let shared = CodeDisplayOptions()

    var wrapLines: Bool {
        didSet { UserDefaults.standard.set(wrapLines, forKey: Self.wrapKey) }
    }

    var showInvisibles: Bool {
        didSet { UserDefaults.standard.set(showInvisibles, forKey: Self.invisiblesKey) }
    }

    private static let wrapKey = "codeman.native.code.wrapLines"
    private static let invisiblesKey = "codeman.native.code.showInvisibles"

    private init() {
        // Wrapping off by default: code is written to a width, and rewrapping it hides that.
        wrapLines = UserDefaults.standard.bool(forKey: Self.wrapKey)
        showInvisibles = UserDefaults.standard.bool(forKey: Self.invisiblesKey)
    }

    /// Render tabs, spaces and line ends visibly.
    ///
    /// ⚠️ Substitutes rather than overlays, so the glyph occupies the same cell the character did
    /// — otherwise revealing invisibles would reflow the very indentation being inspected.
    static func revealing(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\t", with: "→\u{200A}")
            .replacingOccurrences(of: " ", with: "·")
    }
}

/// A menu of display toggles, shared by the file viewer and the step detail.
struct CodeDisplayMenu: View {
    @Bindable var options = CodeDisplayOptions.shared

    var body: some View {
        Menu {
            Toggle("Wrap Lines", isOn: $options.wrapLines)
            Toggle("Show Invisibles", isOn: $options.showInvisibles)
        } label: {
            Image(systemName: "textformat.size")
        }
        .accessibilityLabel("Display options")
        .accessibilityIdentifier("code.displayOptions")
    }
}
