import SwiftUI
import UIKit

/// Agent prose rendered as native SwiftUI.
///
/// ⚠️ `Text(AttributedString(markdown:))` alone is not enough, and the gap is not cosmetic:
/// with `.full` syntax SwiftUI collapses a fenced code block into one run of body-font text with
/// its newlines stripped, so a shell snippet arrives as an unreadable single line. Block structure
/// therefore has to be split here and each kind rendered as its own view — code monospaced and
/// horizontally scrollable, lists with real hanging indents.
///
/// Inline emphasis inside a block *is* delegated to `AttributedString`'s parser
/// (`.inlineOnlyPreservingWhitespace`), so `**bold**`, `` `code` `` and links behave exactly as
/// they do elsewhere in the OS, and nothing here reimplements them.
struct MarkdownText: View {
    let text: String
    var font: Font = .body

    var body: some View {
        // Roomier than the default: agent replies are prose, and 8pt ran paragraphs together.
        VStack(alignment: .leading, spacing: 12) {
            ForEach(MarkdownBlock.parse(text)) { block in
                switch block.kind {
                case .paragraph:
                    Text(MarkdownBlock.inline(block.content))
                        .font(font)
                        // ⚠️ Prose follows the reader's text size; code deliberately does NOT,
                        // because a scaled monospace font breaks the column alignment that makes
                        // diffs and indentation readable.
                        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                case .heading(let level):
                    Text(MarkdownBlock.inline(block.content))
                        .font(headingFont(level))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)

                case .bullet(let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").font(font).foregroundStyle(.secondary)
                        Text(MarkdownBlock.inline(block.content)).font(font).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(depth) * 14)

                case .numbered(let marker, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).font(font.monospacedDigit()).foregroundStyle(.secondary)
                        Text(MarkdownBlock.inline(block.content)).font(font).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(depth) * 14)

                case .quote:
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle().fill(.tertiary).frame(width: 3)
                        Text(MarkdownBlock.inline(block.content))
                            .font(font)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                case .code(let language):
                    CodeBlockView(code: block.content, language: language)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

/// A fenced code block: monospaced, horizontally scrollable, copyable.
///
/// ⚠️ The scroll container is the point. Agent output is full of long shell lines and wrapping
/// them at a phone's width is exactly the mid-word mangling the terminal view suffers from; a
/// code block that scrolls keeps each line intact.
struct CodeBlockView: View {
    let code: String
    var language: String?

    @State private var copied = false
    @Bindable private var display = CodeDisplayOptions.shared

    private var displayCode: String {
        guard display.showInvisibles else { return code }
        return code.components(separatedBy: "\n").map(CodeDisplayOptions.revealing).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                CodeDisplayMenu()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("transcript.code.copy")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            // Wrapping and horizontal scrolling are mutually exclusive: with the scroll view
            // present the content keeps its unwrapped width and the wrap never applies.
            if display.wrapLines {
                HighlightedCode(code: displayCode, language: language, wraps: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HighlightedCode(code: displayCode, language: language, wraps: false)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One parsed markdown block.
struct MarkdownBlock: Identifiable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case bullet(depth: Int)
        case numbered(marker: String, depth: Int)
        case quote
        case code(language: String?)
    }

    let id = UUID()
    let kind: Kind
    let content: String

    /// Inline emphasis via the system parser, with code spans and links styled.
    ///
    /// ⚠️ Two things the parser marks but SwiftUI does not style on its own:
    ///
    /// - A `` `code` `` span carries `inlinePresentationIntent == .code`, and `Text` renders it in
    ///   the body font — indistinguishable from prose, which is exactly wrong for an identifier or
    ///   a flag. The run is re-fonted to monospaced here.
    /// - A bare `https://…` is not markdown link syntax, so it decodes as plain text and is not
    ///   tappable. `NSDataDetector` finds those and attaches the link, matching what every other
    ///   iOS text surface does.
    ///
    /// Falls back to the raw string, which is right: unparseable markdown should still be
    /// readable, not blank.
    static func inline(_ source: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)

        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(.callout, design: .monospaced)
            // Secondary rather than the accent colour: an identifier is set apart by being
            // monospaced, and tinting it as well made prose look like it was full of links.
            attributed[run.range].foregroundColor = .secondary
        }

        autolink(&attributed)
        styleLinks(&attributed)
        return attributed
    }

    /// Links read as prose with an underline, not as accent-coloured text.
    ///
    /// ⚠️ Applied AFTER `autolink`, so it covers both the links markdown declared and the bare
    /// URLs the detector found — SwiftUI tints every link with the accent colour by default, and
    /// overriding it has to happen once, over the finished set.
    private static func styleLinks(_ attributed: inout AttributedString) {
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = .secondary
            attributed[run.range].underlineStyle = .single
        }
    }

    /// Attach links to bare URLs the markdown parser left as plain text.
    private static func autolink(_ attributed: inout AttributedString) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let plain = String(attributed.characters)
        let matches = detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        guard !matches.isEmpty else { return }

        for match in matches {
            guard let url = match.url,
                  let range = Range(match.range, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            // Never overwrite a link the markdown already declared — its text and destination
            // differ deliberately, and the detector only sees the visible text.
            if attributed[lower..<upper].link != nil { continue }
            attributed[lower..<upper].link = url
        }
    }

    /// Split markdown into renderable blocks.
    ///
    /// Deliberately small: headings, fenced code, bullet and numbered lists, block quotes, and
    /// paragraphs. That is what agent output actually contains. Tables and nested HTML are left as
    /// paragraph text rather than half-rendered.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            if !joined.isEmpty { blocks.append(MarkdownBlock(kind: .paragraph, content: joined)) }
        }

        var lines = source.components(separatedBy: "\n")[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code. An unterminated fence runs to the end of the text rather than
            // swallowing the rest as a paragraph — a streamed turn is routinely cut mid-fence.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    body.append(next)
                }
                blocks.append(MarkdownBlock(
                    kind: .code(language: language.isEmpty ? nil : language),
                    content: body.joined(separator: "\n")
                ))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let hashes = headingLevel(trimmed) {
                flushParagraph()
                let content = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(kind: .heading(hashes), content: content))
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .quote, content: String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            let indent = line.prefix { $0 == " " }.count / 2
            if let bullet = bulletContent(trimmed) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .bullet(depth: indent), content: bullet))
                continue
            }
            if let (marker, content) = numberedContent(trimmed) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .numbered(marker: marker, depth: indent), content: content))
                continue
            }

            paragraph.append(line)
        }
        flushParagraph()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func bulletContent(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numberedContent(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (String(digits) + ".", String(rest.dropFirst(2)))
    }
}


/// Source with syntax colouring, rendered line by line.
///
/// ⚠️ Per-line `Text` rather than one attributed string: a code block scrolls horizontally, and a
/// single `Text` would wrap instead of extending — which is what keeps long shell lines intact.
struct HighlightedCode: View {
    let code: String
    var language: String?
    /// When wrapping, each line must be allowed to grow downward instead of extending sideways.
    var wraps: Bool = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let lang = SyntaxHighlighter.Language.named(language)
        let lines = code.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(highlighted(lines, lang).enumerated()), id: \.offset) { _, text in
                text
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: !wraps, vertical: false)
                    .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
            }
        }
    }

    /// Block-comment state has to carry across lines, so the whole block is tokenised in order.
    @MainActor
    private func highlighted(_ lines: [String], _ language: SyntaxHighlighter.Language) -> [Text] {
        var inBlockComment = false
        return lines.map {
            SyntaxHighlighter.highlight($0, language: language, scheme: scheme, inBlockComment: &inBlockComment)
        }
    }
}
