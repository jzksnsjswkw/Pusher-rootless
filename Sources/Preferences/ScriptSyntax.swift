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
    ///
    /// The set is GitHub's own: that theme separates thirteen token classes, but
    /// these six are the ones a reader actually scans for, and the two that carry
    /// most of the effect are ``function`` and ``property`` — a page where every
    /// name is one colour is exactly what makes highlighting look flat.
    enum Kind {
        case keyword
        /// Strings, template literals and regular expressions.
        case string
        case comment
        case number
        /// A name being *read*: a member after a dot, or a property of an
        /// injected object (`pref.key`, `res.status`).
        case property
        /// A name being *called*: `push(`, `fetch(`, `res.json(`.
        case function
        /// A name the platform provides: `JSON`, `Math`, `Object`, `Error`,
        /// `parseInt`, `console`.
        ///
        /// GitHub draws these orange, and it is the one class that makes a page of
        /// code look coloured rather than merely tinted — the eye reads orange as
        /// "not mine", which is exactly what a provided name is.
        case builtin
        /// Ordinary code: identifiers, operators, whitespace, punctuation.
        ///
        /// Only produced by ``tokens(in:)``, which is why it has no colour of its
        /// own — it is the editor's text colour.
        case plain
    }

    /// A coloured run, in UTF-16 units so the range can be handed straight to
    /// TextKit.
    ///
    /// Carries its own text as well as its range. The range is what colouring
    /// needs; the text is what the *formatter* needs, and it has to be the same
    /// tokenisation — a formatter working from its own idea of where a template
    /// literal ends would disagree with the colouring about the same file, which
    /// is how a "format" button corrupts a script.
    struct Span {
        let range: NSRange
        let kind: Kind
        let text: String
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

    /// The objects the runtime puts in scope.
    ///
    /// Drawn in the property colour rather than left plain. GitHub cannot know
    /// about them, but here they are the vocabulary a user is looking up — the
    /// thing that says a script is written against the right API — so `pref` and
    /// `bullet` standing out is the one place this palette deviates, and it
    /// deviates by using a colour the theme already defines for names.
    static let runtimeNames: Set<String> = [
        "bullet", "device", "pref", "localStorage", "console", "globalThis",
    ]

    /// The runtime's callable names. They are recognised as function calls by the
    /// same lookahead as any other name, and listed here only so the intent is
    /// written down: `push` and `keep` are the two the contract is about.
    static let runtimeFunctions: Set<String> = ["push", "fetch", "keep"]

    /// The platform's own names, taken from highlight.js's list for JavaScript so
    /// that this agrees with the theme it imitates.
    ///
    /// Only the ones a script has any use for: `window`, `document`, `module` and
    /// `self` are not reachable here, and colouring names that cannot appear would
    /// be colouring nothing.
    static let builtInNames: Set<String> = [
        // Fundamental objects and their friends.
        "Object", "Function", "Boolean", "Symbol", "Number", "BigInt", "Math",
        "Date", "String", "RegExp", "Array", "Map", "Set", "WeakMap", "WeakSet",
        "JSON", "Promise", "Proxy", "Reflect", "Intl",
        // Errors.
        "Error", "EvalError", "RangeError", "ReferenceError", "SyntaxError",
        "TypeError", "URIError",
        // Functions.
        "eval", "isFinite", "isNaN", "parseFloat", "parseInt", "decodeURI",
        "decodeURIComponent", "encodeURI", "encodeURIComponent", "escape",
        "unescape",
        // Timers, which a hook has no business using but may be tempted by.
        "setInterval", "setTimeout", "clearInterval", "clearTimeout",
    ]

    // MARK: - Scanning

    /// Every coloured run in `text`, in order.
    ///
    /// Nothing is emitted for ordinary code: the editor's own text colour is
    /// already right for identifiers, operators and punctuation, and emitting
    /// spans only for what differs keeps the attribute pass short.
    /// Every coloured run in `text`, in order, with the gaps left out.
    ///
    /// For colouring: the editor's own text colour already covers whatever is not
    /// here, and a span per gap would be work for nothing.
    static func spans(in text: String) -> [Span] {
        scan(text)
    }

    /// Every run in `text`, in order, **including** the ones that are ordinary
    /// code.
    ///
    /// For formatting, which needs every character exactly once: the gaps are
    /// emitted as ``Kind/plain`` so that joining the tokens reproduces the input
    /// byte for byte. That property is what the formatter's tests check, because
    /// a formatter that can lose a character is worse than no formatter.
    static func tokens(in text: String) -> [Span] {
        let scanned = scan(text)
        guard !scanned.isEmpty else {
            return text.isEmpty ? [] : [
                // Before the first token.
                Span(range: NSRange(location: 0, length: (text as NSString).length),
                     kind: .plain, text: text)
            ]
        }

        let ns = text as NSString
        var all: [Span] = []
        var cursor = 0
        for span in scanned {
            if span.range.location > cursor {
                let gap = NSRange(location: cursor, length: span.range.location - cursor)
                all.append(Span(range: gap, kind: .plain, text: ns.substring(with: gap)))
            }
            all.append(span)
            cursor = NSMaxRange(span.range)
        }
        if cursor < ns.length {
            let gap = NSRange(location: cursor, length: ns.length - cursor)
            all.append(Span(range: gap, kind: .plain, text: ns.substring(with: gap)))
        }
        return all
    }

    private static func scan(_ text: String) -> [Span] {
        // The units and the string are paired: the scanner works in UTF-16 so its
        // ranges are TextKit's, and a token's text is the substring over exactly
        // that range.
        let ns = text as NSString
        var scanner = Scanner(units: Array(text.utf16), text: ns)
        scanner.run()
        return scanner.spans
    }

    /// A single left-to-right pass.
    private struct Scanner {
        let units: [UInt16]
        /// The whole text, for slicing a token's characters back out.
        let text: NSString
        var index = 0
        var spans: [Span] = []

        /// What the previous meaningful character was, which is what decides
        /// whether a `/` divides or begins a regular expression.
        var lastSignificant: UInt16 = 0

        /// Set for the identifiers that may be followed by a regular expression —
        /// `return /re/` is a literal, `count /re/` is division.
        var lastWasKeywordAllowingRegex = false

        init(units: [UInt16], text: NSString) {
            self.units = units
            self.text = text
        }

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
                    // The `${` is emitted as part of the template rather than left
                    // as a gap: it is template syntax, and a gap would be ordinary
                    // text to anything reading the token stream — which is how the
                    // formatter came to treat an interpolation's braces as a block
                    // and indent the expression inside a string.
                    emit(index, index + 2, .string)
                    index += 2
                    skipExpression()
                    // Its closing `}` likewise.
                    if index <= count, index > 0, units[index - 1] == closeBrace {
                        emit(index - 1, index, .string)
                    }
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
                    // Recorded like anywhere else, or a `.` inside a `${ … }` hole
                    // would not mark what follows it as a property — which is the
                    // most visible place in a script for that to go wrong, since
                    // building a URL out of `pref` fields is the common case.
                    if !isWhitespace(c) { lastSignificant = c }
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

            if keywords.contains(name) {
                emit(start, index, .keyword)
                lastWasKeywordAllowingRegex = keywordsAllowingRegex.contains(name)
            } else if builtInNames.contains(name) {
                emit(start, index, .builtin)
            } else if runtimeNames.contains(name) {
                emit(start, index, .property)
            } else if runtimeFunctions.contains(name), nextMeaningfulCharacter == openParen {
                emit(start, index, .function)
            } else if isFunctionCall {
                // Any name followed by `(`: `res.json(`, `Number(`, `add(`.
                emit(start, index, .function)
            } else if isPropertyName {
                // A key in an object literal, or a member after a dot.
                emit(start, index, .property)
            }
            // Anything else is left uncoloured: the editor's own text colour
            // already covers ordinary identifiers.

            lastSignificant = identifierMarker
        }

        /// The next character that is not whitespace, so `foo (` is still a call.
        private var nextMeaningfulCharacter: UInt16 {
            var i = index
            while i < count, isWhitespace(units[i]) { i += 1 }
            return at(i)
        }

        /// Whether the identifier just read is being called.
        private var isFunctionCall: Bool { nextMeaningfulCharacter == openParen }

        /// Whether the identifier just read names a value rather than a variable:
        /// a member after `.`, or a key in an object literal.
        private var isPropertyName: Bool {
            // `pref.key`, `bullet.title`, `res.status`.
            if lastSignificant == dot { return true }
            // `{ key: value }` — a key is followed by a colon, and a colon only
            // appears there or in a ternary, which the brace test below rules out.
            guard nextMeaningfulCharacter == colon else { return false }
            return isInsideObjectLiteral
        }

        /// Whether the cursor is inside `{ … }` rather than a block.
        ///
        /// Approximated from the last significant character: inside an object
        /// literal, the things before a key are `{`, `,` or another key's value.
        /// A block's `:` only appears as a label, which a script this app runs
        /// does not use — and if it did, the cost is one word in the wrong colour.
        private var isInsideObjectLiteral: Bool {
            switch lastSignificant {
            case openBrace, comma:
                return true
            default:
                return false
            }
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
            let range = NSRange(location: start, length: end - start)
            spans.append(Span(range: range, kind: kind, text: text.substring(with: range)))
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

    /// The view being colouring. Weak, and only for its `traitCollection`: the
    /// palette depends on the appearance, and a text storage has none of its own.
    weak var host: UITextView?

    /// The appearance the current colours were chosen for, so a change of
    /// appearance can be noticed and the document recoloured.
    private var paletteIsDark: Bool?

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

    /// Recolours when the device switches between light and dark.
    ///
    /// The colours are baked into the storage on every edit, so without this the
    /// document would keep the palette it was typed in until the next keystroke.
    func appearanceChanged() {
        guard host != nil else { return }
        let isDark = host?.traitCollection.userInterfaceStyle == .dark
        guard isDark != paletteIsDark else { return }
        applyColours()
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
        let traits = host?.traitCollection ?? UITraitCollection.current
        paletteIsDark = traits.userInterfaceStyle == .dark
        addAttribute(
            .foregroundColor, value: ScriptPalette.plain(in: traits), range: whole
        )
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

/// An editor text view that recolours itself when the appearance changes.
///
/// A subclass exists for exactly one reason: `traitCollectionDidChange` is only
/// delivered to a view, and the colours live in the text storage.
private final class ScriptEditorTextView: UITextView {
    weak var storage: ScriptTextStorage?

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.userInterfaceStyle != previous?.userInterfaceStyle else {
            return
        }
        textColor = ScriptPalette.plain(in: traitCollection)
        storage?.appearanceChanged()
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

        let textView = ScriptEditorTextView(frame: .zero, textContainer: container)
        storage.host = textView
        textView.storage = storage
        // The theme's own foreground, not `.label`: ordinary code is drawn in
        // this colour, so using the system label colour would make the plain text
        // and the coloured tokens look like they came from two palettes.
        textView.textColor = ScriptPalette.plain(in: textView.traitCollection)
        return textView
    }
}

/// The colours, taken from GitHub's own syntax theme.
///
/// These are GitHub's `prettylights` values — the palette its website actually
/// uses, as shipped with highlight.js. The first attempt took a *different*
/// stylesheet of the same name, an older base16 variant that came with a
/// third-party library; it looked nearly right and read flat, which is the whole
/// difference between a theme and a lookalike.
///
/// The classes are assigned the way GitHub assigns them, including the one that
/// carries most of the effect: names the platform provides (`JSON`, `Math`,
/// `Error`, `parseInt`) are orange, so a reader sees at a glance what is the
/// script's own and what is given.
enum ScriptPalette {

    /// The palette for one appearance.
    struct Theme {
        let keyword: UIColor
        let string: UIColor
        let comment: UIColor
        let number: UIColor
        let function: UIColor
        let builtin: UIColor
        let plain: UIColor

        init(
            keyword: String, string: String, comment: String, number: String,
            function: String, builtin: String, plain: String
        ) {
            self.keyword = UIColor(hex: keyword)
            self.string = UIColor(hex: string)
            self.comment = UIColor(hex: comment)
            self.number = UIColor(hex: number)
            self.function = UIColor(hex: function)
            self.builtin = UIColor(hex: builtin)
            self.plain = UIColor(hex: plain)
        }
    }

    /// `github` — the light theme. `#24292e` foreground, not black.
    static let light = Theme(
        keyword: "#d73a49",     // prettylights-syntax-keyword
        string: "#032f62",      // prettylights-syntax-string
        comment: "#6a737d",     // prettylights-syntax-comment
        number: "#005cc5",      // prettylights-syntax-constant
        function: "#6f42c1",    // prettylights-syntax-entity
        builtin: "#e36209",     // prettylights-syntax-variable
        plain: "#24292e"
    )

    /// `github-dark` — the same palette for a dark page.
    static let dark = Theme(
        keyword: "#ff7b72",
        string: "#a5d6ff",
        comment: "#8b949e",
        number: "#79c0ff",
        function: "#d2a8ff",
        builtin: "#ffa657",
        plain: "#c9d1d9"
    )

    static func color(for kind: ScriptSyntax.Kind) -> UIColor {
        UIColor { traits in
            let theme = traits.userInterfaceStyle == .dark ? dark : light
            switch kind {
            case .keyword: return theme.keyword
            case .string: return theme.string
            case .comment: return theme.comment
            case .number: return theme.number
            // An object key is GitHub's `hljs-attr`, which shares the constant
            // colour with numbers — the same blue a reader already associates
            // with "a literal value".
            case .property: return theme.number
            case .function: return theme.function
            case .builtin: return theme.builtin
            case .plain: return theme.plain
            }
        }
    }

    /// The colour ordinary code is drawn in, which the editor's own text colour
    /// also has to be set to or the page will not match the theme.
    static func plain(in traits: UITraitCollection) -> UIColor {
        (traits.userInterfaceStyle == .dark ? dark : light).plain
    }
}

extension UIColor {
    /// A colour from `#RRGGBB` or `#RGB`, the two forms the theme files use.
    ///
    /// A convenience rather than a dependency on the theme files themselves: the
    /// values above are quoted from them, and being able to read the same string
    /// here as in the stylesheet is what makes comparing the two possible.
    convenience init(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }

        // Three-digit form: each digit is doubled, so #abc is #aabbcc.
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }

        var value: UInt64 = 0
        guard digits.count == 6, Scanner(string: digits).scanHexInt64(&value) else {
            self.init(white: 0.5, alpha: 1)
            return
        }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
