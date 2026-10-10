import UIKit

/// JavaScript colouring for the two editors a user writes code in.
///
/// A hand-written scanner rather than a set of regular expressions. Highlighting
/// JavaScript by pattern is the classic source of wrong colours, because the same
/// characters mean different things in different places: `/` begins a regular
/// expression or divides, depending on what came before it; a quote inside a
/// comment is not a string; a quote inside a *regular expression* is not a string
/// either — and getting that one wrong makes a line of `/["']/` swallow the rest
/// of the file as one enormous string. A single left-to-right pass with an
/// explicit state has none of those ambiguities, and it is linear in the text
/// length, which matters because it runs on every keystroke.
enum ScriptSyntax {

    /// What a run of characters is, as far as colouring is concerned.
    enum Kind {
        case keyword
        /// Strings and template literals.
        case string
        case comment
        case number
        /// A name this app injects — `push`, `bullet`, `pref`, `fetch`.
        case runtime
    }

    /// A coloured run, in UTF-16 units so the range can be handed straight to
    /// TextKit.
    struct Span {
        let range: NSRange
        let kind: Kind
    }

    // MARK: - Vocabulary

    /// The language's keywords.
    ///
    /// Including the contextual ones (`await`, `yield`, `of`, `get`, `set`) and
    /// the three literal names, because a reader treats them all as keywords —
    /// `null` and `undefined` are not punctuation, and colouring them as ordinary
    /// text is what makes code look flat.
    private static let keywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue",
        "debugger", "default", "delete", "do", "else", "export", "extends",
        "finally", "for", "function", "get", "if", "import", "in", "instanceof",
        "let", "new", "of", "return", "set", "static", "super", "switch", "this",
        "throw", "try", "typeof", "var", "void", "while", "with", "yield",
        "null", "true", "false", "undefined",
    ]

    /// The names the runtime puts in scope.
    ///
    /// Coloured apart from the language because they are the vocabulary of *this*
    /// app — the thing a user is looking up when they open an editor — and because
    /// seeing `push` in a different colour from the code around it is the quickest
    /// confirmation that a script is written against the right API.
    static let runtimeNames: Set<String> = [
        "push", "bullet", "device", "pref", "fetch", "localStorage", "console",
        "keep", "globalThis",
    ]

    // MARK: - Scanning

    /// Every coloured run in `text`, in order.
    ///
    /// Nothing is emitted for ordinary code: the editor's own text colour is
    /// already right for identifiers, operators and punctuation, and emitting
    /// spans only for what differs keeps the attribute pass short.
    static func spans(in text: String) -> [Span] {
        var scanner = Scanner(units: Array(text.utf16))
        scanner.run()
        return scanner.spans
    }

    /// A single left-to-right pass.
    private struct Scanner {
        let units: [UInt16]
        var index = 0
        var spans: [Span] = []

        /// What the previous meaningful character was, which is what decides
        /// whether a `/` divides or begins a regular expression.
        var lastSignificant: UInt16 = 0

        /// Set for the identifiers that may be followed by a regular expression —
        /// `return /re/` is a literal, `count /re/` is division.
        var lastWasKeywordAllowingRegex = false

        init(units: [UInt16]) { self.units = units }

        var count: Int { units.count }
        func at(_ i: Int) -> UInt16 { i < count ? units[i] : 0 }

        mutating func run() {
            while index < count {
                let c = units[index]

                if c == slash, at(index + 1) == slash {
                    scanLineComment()
                } else if c == slash, at(index + 1) == star {
                    scanBlockComment()
                } else if c == slash, regexCanStartHere {
                    scanRegex()
                } else if c == quote || c == apostrophe {
                    scanString(quote: c)
                } else if c == backtick {
                    scanTemplate()
                } else if isDigit(c), !isIdentifierPart(lastSignificant) {
                    scanNumber()
                } else if isIdentifierStart(c) {
                    scanIdentifier()
                } else {
                    if !isWhitespace(c) {
                        lastSignificant = c
                        lastWasKeywordAllowingRegex = false
                    }
                    index += 1
                }
            }
        }

        // MARK: Comments

        private mutating func scanLineComment() {
            let start = index
            while index < count, units[index] != newline, units[index] != carriageReturn {
                index += 1
            }
            emit(start, index, .comment)
            // A comment is not a value, so the character before it is still what
            // decides the next `/`.
        }

        private mutating func scanBlockComment() {
            let start = index
            defer { emit(start, index, .comment) }
            index += 2
            while index < count {
                if units[index] == star, at(index + 1) == slash {
                    index += 2
                    break
                }
                index += 1
            }
        }

        // MARK: Strings

        private mutating func scanString(quote: UInt16) {
            let start = index
            index += 1
            while index < count {
                let c = units[index]
                if c == backslash {
                    index += 2
                    continue
                }
                // A newline ends it: an unterminated string must not colour the
                // rest of the file, which is what happens when the scanner keeps
                // looking for a closing quote that was never typed.
                if c == newline || c == carriageReturn { break }
                if c == quote {
                    index += 1
                    break
                }
                index += 1
            }
            emit(start, min(index, count), .string)
            lastSignificant = quote
            lastWasKeywordAllowingRegex = false
        }

        /// A template literal, with its interpolations coloured as code.
        ///
        /// `${ … }` is a hole in the string rather than part of it, so the
        /// expression inside is scanned as JavaScript — which is also what lets a
        /// nested template or a quote inside the hole come out right.
        private mutating func scanTemplate() {
            index += 1
            var literalStart = index

            while index < count {
                let c = units[index]
                if c == backslash {
                    index += 2
                    continue
                }
                if c == backtick {
                    index += 1
                    break
                }
                if c == dollar, at(index + 1) == openBrace {
                    emit(literalStart, index, .string)
                    index += 2
                    skipExpression()
                    literalStart = index
                    continue
                }
                index += 1
            }
            emit(literalStart, min(index, count), .string)
            lastSignificant = backtick
            lastWasKeywordAllowingRegex = false
        }

        /// Consumes a `${ … }` hole, balancing nested braces.
        ///
        /// The braces are counted rather than searched for, because the hole may
        /// contain an object literal, another template — anything with braces of
        /// its own. Nested strings, templates and comments are skipped whole so
        /// their braces do not count.
        private mutating func skipExpression() {
            var depth = 1
            while index < count, depth > 0 {
                let c = units[index]
                if c == openBrace {
                    depth += 1
                    index += 1
                } else if c == closeBrace {
                    depth -= 1
                    index += 1
                } else if c == slash, at(index + 1) == slash {
                    scanLineComment()
                } else if c == slash, at(index + 1) == star {
                    scanBlockComment()
                } else if c == quote || c == apostrophe {
                    scanString(quote: c)
                } else if c == backtick {
                    scanTemplate()
                } else if isIdentifierStart(c) {
                    scanIdentifier()
                } else if isDigit(c) {
                    scanNumber()
                } else {
                    index += 1
                }
            }
        }

        // MARK: Regular expressions

        /// Whether a `/` here begins a literal rather than dividing.
        ///
        /// True at the start, after an operator or opening bracket, and after a
        /// keyword that expects an expression — false after anything that can end
        /// one, which is what makes `a / b` division.
        private var regexCanStartHere: Bool {
            if lastWasKeywordAllowingRegex { return true }
            switch lastSignificant {
            case 0, openParen, openBracket, openBrace, closeBrace, comma, semicolon,
                 equals, colon, question, exclamation, ampersand, pipe, plus, minus,
                 star, percent, caret, tilde, lessThan, greaterThan, newline,
                 carriageReturn:
                return true
            default:
                // After an identifier, number, `)` or `]` a slash divides.
                return false
            }
        }

        private mutating func scanRegex() {
            let start = index
            index += 1
            var inClass = false
            while index < count {
                let c = units[index]
                if c == backslash {
                    index += 2
                    continue
                }
                if c == newline || c == carriageReturn { break }
                if c == openBracket { inClass = true }
                if c == closeBracket { inClass = false }
                if c == slash, !inClass {
                    index += 1
                    // Flags.
                    while index < count, isIdentifierPart(units[index]) { index += 1 }
                    break
                }
                index += 1
            }
            emit(start, min(index, count), .string)
            lastSignificant = slash
            lastWasKeywordAllowingRegex = false
        }

        // MARK: Numbers, identifiers

        private mutating func scanNumber() {
            let start = index
            // A leading `0x`, `0b`, `0o` changes what may follow, but a run of
            // digits, letters, dots and underscores covers all of them — and
            // `1_000` is a number, not a number and an identifier.
            while index < count {
                let c = units[index]
                if isDigit(c) || isIdentifierPart(c) || c == dot { index += 1 } else { break }
            }
            // A trailing `n` on a BigInt is part of the number; the loop above
            // already took it.
            emit(start, index, .number)
            lastSignificant = digitMarker
            lastWasKeywordAllowingRegex = false
        }

        private mutating func scanIdentifier() {
            let start = index
            while index < count, isIdentifierPart(units[index]) { index += 1 }
            let name = String(decoding: units[start..<index], as: UTF16.self)

            // Cleared first, then set only by the keyword that permits one: an
            // identifier of any kind ends the window in which a `/` begins a
            // literal.
            lastWasKeywordAllowingRegex = false
            if runtimeNames.contains(name) {
                emit(start, index, .runtime)
            } else if keywords.contains(name) {
                emit(start, index, .keyword)
                lastWasKeywordAllowingRegex = keywordsAllowingRegex.contains(name)
            }
            // Anything else is left uncoloured: the editor's own text colour
            // already covers identifiers.

            lastSignificant = identifierMarker
        }

        /// Keywords after which an expression — and so a regular expression — may
        /// begin.
        private var keywordsAllowingRegex: Set<String> {
            ["return", "typeof", "instanceof", "in", "of", "new", "delete", "void",
             "case", "do", "else", "yield", "await", "throw"]
        }

        // MARK: Emitting

        private mutating func emit(_ start: Int, _ end: Int, _ kind: Kind) {
            guard end > start else { return }
            spans.append(Span(range: NSRange(location: start, length: end - start), kind: kind))
        }

        // MARK: Characters

        private func isWhitespace(_ c: UInt16) -> Bool {
            c == space || c == tab || c == newline || c == carriageReturn
        }

        private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }

        /// `$` and `_` as well as letters. Non-ASCII letters are left out: a
        /// JavaScript identifier may contain them, but a script that pushes a
        /// notification does not, and reading them as ordinary characters keeps
        /// the scanner honest about what it does not understand.
        private func isIdentifierStart(_ c: UInt16) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == underscore || c == dollar
        }

        private func isIdentifierPart(_ c: UInt16) -> Bool {
            isIdentifierStart(c) || isDigit(c)
        }

        // Stand-ins for "the previous token was one of these", so a single
        // comparison covers them. They are not valid UTF-16 as characters.
        private var identifierMarker: UInt16 { 0xFFFF }
        private var digitMarker: UInt16 { 0xFFFE }
    }

    // MARK: - Character codes

    private static let space: UInt16 = 32, tab: UInt16 = 9, newline: UInt16 = 10
    private static let carriageReturn: UInt16 = 13
    private static let quote: UInt16 = 34, apostrophe: UInt16 = 39, backtick: UInt16 = 96
    private static let dollar: UInt16 = 36, underscore: UInt16 = 95, dot: UInt16 = 46
    private static let backslash: UInt16 = 92
    private static let slash: UInt16 = 47, star: UInt16 = 42
    private static let openBrace: UInt16 = 123, closeBrace: UInt16 = 125
    private static let openParen: UInt16 = 40, openBracket: UInt16 = 91
    private static let closeBracket: UInt16 = 93, closeParen: UInt16 = 41
    private static let comma: UInt16 = 44, semicolon: UInt16 = 59, equals: UInt16 = 61
    private static let colon: UInt16 = 58, question: UInt16 = 63, exclamation: UInt16 = 33
    private static let ampersand: UInt16 = 38, pipe: UInt16 = 124, caret: UInt16 = 94
    private static let tilde: UInt16 = 126, plus: UInt16 = 43, minus: UInt16 = 45
    private static let percent: UInt16 = 37
    private static let lessThan: UInt16 = 60, greaterThan: UInt16 = 62
}

// MARK: - Applying

/// A text view whose JavaScript colours itself.
///
/// A `NSTextStorage` subclass rather than attributes written on after each
/// keystroke, because that is the one place where colouring is guaranteed not to
/// interfere with what the user is doing. Attributes written from the delegate
/// would enter the undo stack (so undo would appear to do nothing but change
/// colours), re-enter the delegate, and fight the text input system over the
/// typing attributes. Here the colours are applied during the storage's own edit
/// cycle, after the characters are in and before anything is laid out.
final class ScriptTextStorage: NSTextStorage {

    private let backing = NSMutableAttributedString()

    override var string: String { backing.string }

    override func attributes(
        at location: Int, effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited(
            .editedCharacters, range: range,
            changeInLength: (str as NSString).length - range.length
        )
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    /// Guards the recursive edit this method's own attribute changes would
    /// otherwise start: `processEditing` runs on the outermost `endEditing`, and
    /// colouring inside it appends more attribute edits.
    private var isColouring = false

    override func processEditing() {
        if !isColouring { applyColours() }
        super.processEditing()
    }

    private func applyColours() {
        let whole = NSRange(location: 0, length: backing.length)
        guard whole.length > 0 else { return }
        // A very large document is not a script this app runs — it is a paste
        // mistake — and colouring it on every keystroke is not worth the delay.
        guard whole.length <= 60_000 else { return }

        isColouring = true
        beginEditing()

        // The default first, over everything. Without it a character keeps
        // whatever colour it was typed into — deleting a quote would leave the
        // word it had enclosed red — because colouring only ever *set* the tokens
        // it recognised.
        addAttribute(.foregroundColor, value: UIColor.label, range: whole)
        for span in ScriptSyntax.spans(in: backing.string)
        where NSMaxRange(span.range) <= whole.length {
            addAttribute(
                .foregroundColor, value: ScriptPalette.color(for: span.kind),
                range: span.range
            )
        }

        endEditing()
        isColouring = false
    }
}

extension UITextView {
    /// An editor text view with JavaScript colouring, ready to be laid out.
    ///
    /// Built here rather than at each call site so the layout stack is assembled
    /// in one place: a text view with its own storage has to be constructed with
    /// that stack, and getting it wrong — an unowned container, a missing
    /// `widthTracksTextView` — produces a text view that does not scroll or wrap
    /// rather than one that fails loudly.
    static func scriptEditor() -> UITextView {
        let storage = ScriptTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = UITextView(frame: .zero, textContainer: container)
        textView.textColor = UIColor.label
        return textView
    }
}

/// The colours, adapted to the appearance.
///
/// Tuned for reading rather than for showing off: the keywords are a muted
/// magenta and the strings a dark red in light mode, which is roughly where a
/// long-standing editor puts them, so the result looks familiar rather than
/// invented. Each is darkened or lightened for its appearance because the same
/// hue cannot carry enough contrast on both a white and a black page.
enum ScriptPalette {
    static func color(for kind: ScriptSyntax.Kind) -> UIColor {
        switch kind {
        case .keyword:
            return adaptive(light: (0.61, 0.14, 0.55), dark: (0.99, 0.37, 0.62))
        case .string:
            return adaptive(light: (0.77, 0.10, 0.09), dark: (0.99, 0.42, 0.36))
        case .number:
            return adaptive(light: (0.11, 0.00, 0.81), dark: (0.82, 0.75, 0.41))
        case .comment:
            return adaptive(light: (0.36, 0.42, 0.47), dark: (0.42, 0.47, 0.53))
        case .runtime:
            return adaptive(light: (0.06, 0.41, 0.63), dark: (0.40, 0.72, 1.00))
        }
    }

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)
    ) -> UIColor {
        UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }
}
