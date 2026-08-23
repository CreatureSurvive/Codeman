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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownBlock.parse(text)) { block in
                switch block.kind {
                case .paragraph:
                    Text(MarkdownBlock.inline(block.content))
                        .font(font)
                        .textSelection(.enabled)

                case .heading(let level):
                    Text(MarkdownBlock.inline(block.content))
                        .font(headingFont(level))
                        .textSelection(.enabled)
                        .padding(.top, 2)

                case .bullet(let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").font(font).foregroundStyle(.secondary)
                        Text(MarkdownBlock.inline(block.content)).font(font).textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(depth) * 14)

                case .numbered(let marker, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).font(font.monospacedDigit()).foregroundStyle(.secondary)
                        Text(MarkdownBlock.inline(block.content)).font(font).textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(depth) * 14)

                case .quote:
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle().fill(.tertiary).frame(width: 3)
                        Text(MarkdownBlock.inline(block.content))
                            .font(font)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
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

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Inline emphasis via the system parser. Falls back to the raw string, which is right:
    /// unparseable markdown should still be readable, not blank.
    static func inline(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
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
