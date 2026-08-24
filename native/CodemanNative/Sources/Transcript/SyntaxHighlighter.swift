import SwiftUI

/// Lightweight syntax colouring for code blocks and the file viewer.
///
/// ⚠️ Hand-written rather than a package. The alternatives (Splash, Highlightr) either pull in a
/// JavaScript engine or target one language, and this has to run on every code block in a long
/// transcript while the user scrolls. Correctness here means "reads better than monochrome", not
/// "matches a compiler" — so it tokenises comments, strings, numbers and keywords, and leaves
/// everything else alone rather than guessing at structure.
///
/// One pass, no backtracking: comments and strings win over keywords, because a keyword inside a
/// string is not a keyword.
enum SyntaxHighlighter {
    /// Languages worth distinguishing. Anything else falls back to a shared keyword set, which
    /// still colours strings, numbers and comments correctly.
    enum Language {
        case swift, javascript, typescript, python, json, shell, markup, plain

        /// Map a file extension or a fence label onto a language.
        static func named(_ raw: String?) -> Language {
            switch (raw ?? "").lowercased() {
            case "swift": return .swift
            case "js", "jsx", "mjs", "cjs": return .javascript
            case "ts", "tsx": return .typescript
            case "py", "python": return .python
            case "json": return .json
            case "sh", "bash", "zsh", "shell", "console": return .shell
            case "html", "xml", "svg": return .markup
            default: return .plain
            }
        }

        var keywords: Set<String> {
            switch self {
            case .swift:
                return ["func", "let", "var", "if", "else", "guard", "return", "struct", "class",
                        "enum", "protocol", "extension", "import", "self", "init", "for", "in",
                        "while", "switch", "case", "default", "try", "catch", "throw", "throws",
                        "async", "await", "private", "public", "internal", "static", "some", "any",
                        "nil", "true", "false", "where", "as", "is", "defer", "typealias"]
            case .javascript, .typescript:
                return ["function", "const", "let", "var", "if", "else", "return", "class",
                        "extends", "import", "export", "from", "default", "for", "while", "switch",
                        "case", "try", "catch", "throw", "async", "await", "new", "this", "null",
                        "undefined", "true", "false", "typeof", "interface", "type", "enum"]
            case .python:
                return ["def", "class", "if", "elif", "else", "return", "import", "from", "as",
                        "for", "while", "try", "except", "finally", "raise", "with", "lambda",
                        "None", "True", "False", "and", "or", "not", "in", "is", "async", "await"]
            case .json:
                return ["true", "false", "null"]
            case .shell:
                return ["if", "then", "else", "fi", "for", "in", "do", "done", "while", "case",
                        "esac", "function", "return", "export", "local", "echo", "cd", "exit"]
            case .markup:
                return []
            case .plain:
                return ["if", "else", "return", "function", "class", "import", "true", "false", "null"]
            }
        }

        /// Line-comment markers. Block comments are handled separately for the C-family.
        var lineComment: String? {
            switch self {
            case .python, .shell: return "#"
            case .json, .markup: return nil
            default: return "//"
            }
        }

        var hasBlockComments: Bool {
            switch self {
            case .swift, .javascript, .typescript: return true
            default: return false
            }
        }
    }

    /// A coloured run of source.
    struct Token: Equatable {
        enum Kind: Equatable {
            case plain, keyword, string, number, comment, type

            func color(_ scheme: ColorScheme) -> Color {
                switch self {
                case .plain: return .primary
                case .keyword: return scheme == .dark ? Color(red: 1.0, green: 0.47, blue: 0.78) : .pink
                case .string: return scheme == .dark ? Color(red: 0.99, green: 0.42, blue: 0.35) : .red
                case .number: return scheme == .dark ? Color(red: 0.64, green: 0.62, blue: 1.0) : .purple
                case .comment: return .secondary
                case .type: return scheme == .dark ? Color(red: 0.36, green: 0.82, blue: 0.98) : .teal
                }
            }
        }

        var text: String
        var kind: Kind
    }

    /// Tokenise one line. Line-scoped on purpose: the file viewer renders row by row, and a
    /// whole-file pass would have to be redone on every scroll.
    ///
    /// ⚠️ `inBlockComment` carries multi-line `/* … */` state across lines, so the caller must
    /// thread it through rather than tokenising lines independently.
    static func tokenize(_ line: String, language: Language, inBlockComment: inout Bool) -> [Token] {
        guard !line.isEmpty else { return [] }
        if language == .plain, line.count > 400 {
            // Very long unstructured lines are not worth the pass; the terminal output that
            // produces them has no syntax to show.
            return [Token(text: line, kind: .plain)]
        }

        var tokens: [Token] = []
        var current = ""
        var currentKind = Token.Kind.plain
        let characters = Array(line)
        var index = 0

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(Token(text: current, kind: currentKind))
            current = ""
            currentKind = .plain
        }

        func emit(_ text: String, _ kind: Token.Kind) {
            flush()
            tokens.append(Token(text: text, kind: kind))
        }

        while index < characters.count {
            let character = characters[index]

            if inBlockComment {
                // Consume until the terminator; the rest of the line is comment either way.
                if character == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                    current.append("*/")
                    index += 2
                    inBlockComment = false
                    currentKind = .comment
                    flush()
                    continue
                }
                currentKind = .comment
                current.append(character)
                index += 1
                continue
            }

            // Block comment open.
            if language.hasBlockComments, character == "/", index + 1 < characters.count,
               characters[index + 1] == "*" {
                flush()
                inBlockComment = true
                currentKind = .comment
                current.append("/*")
                index += 2
                continue
            }

            // Line comment: everything to end of line.
            if let marker = language.lineComment, character == marker.first,
               line.dropFirst(index).hasPrefix(marker) {
                emit(String(characters[index...]), .comment)
                return tokens
            }

            // Strings. Escapes are consumed so `"a\"b"` stays one token.
            if character == "\"" || character == "'" || character == "`" {
                flush()
                var literal = String(character)
                var scan = index + 1
                while scan < characters.count {
                    let next = characters[scan]
                    literal.append(next)
                    if next == "\\", scan + 1 < characters.count {
                        literal.append(characters[scan + 1])
                        scan += 2
                        continue
                    }
                    scan += 1
                    if next == character { break }
                }
                tokens.append(Token(text: literal, kind: .string))
                index = scan
                continue
            }

            // Identifiers and keywords.
            if character.isLetter || character == "_" || character == "@" || character == "$" {
                flush()
                var word = ""
                var scan = index
                while scan < characters.count,
                      characters[scan].isLetter || characters[scan].isNumber
                        || characters[scan] == "_" || characters[scan] == "@" || characters[scan] == "$" {
                    word.append(characters[scan])
                    scan += 1
                }
                let bare = word.hasPrefix("@") ? String(word.dropFirst()) : word
                if language.keywords.contains(bare) || language.keywords.contains(word) {
                    tokens.append(Token(text: word, kind: .keyword))
                } else if let first = bare.first, first.isUppercase {
                    // A capitalised identifier is a type often enough to be worth colouring, and
                    // being wrong here is cosmetic.
                    tokens.append(Token(text: word, kind: .type))
                } else {
                    tokens.append(Token(text: word, kind: .plain))
                }
                index = scan
                continue
            }

            // Numbers, including hex and decimals.
            if character.isNumber {
                flush()
                var number = ""
                var scan = index
                while scan < characters.count,
                      characters[scan].isHexDigit || characters[scan] == "."
                        || characters[scan] == "x" || characters[scan] == "_" {
                    number.append(characters[scan])
                    scan += 1
                }
                tokens.append(Token(text: number, kind: .number))
                index = scan
                continue
            }

            current.append(character)
            index += 1
        }

        flush()
        return tokens
    }

    /// Build a coloured `Text` for one line.
    @MainActor
    static func highlight(
        _ line: String,
        language: Language,
        scheme: ColorScheme,
        inBlockComment: inout Bool
    ) -> Text {
        let tokens = tokenize(line, language: language, inBlockComment: &inBlockComment)
        guard !tokens.isEmpty else { return Text(" ") }
        return tokens.reduce(Text("")) { partial, token in
            partial + Text(token.text).foregroundColor(token.kind.color(scheme))
        }
    }
}
