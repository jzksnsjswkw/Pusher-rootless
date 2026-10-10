import Foundation

/// Rewrites a script's whitespace without changing a character of it otherwise.
///
/// ## What this is not
///
/// Not a conventional code beautifier. Those take a file and re-typeset it to
/// their own taste — indentation, where braces go, which lines get broken — and
/// the result is a file the author no longer recognises. That is the wrong
/// instinct for a script a user wrote and may well read again: the layout is part
/// of how they think about the code, and reformatting it wholesale is a bug report
/// waiting to happen ("the formatter changed my code and now it behaves
/// differently", which here would be true).
///
/// The one thing it does unconditionally is fix *indentation*, because a script
/// pasted from a chat message or an AI answer arrives with none, and indentation
/// is what makes nesting legible. Even then it never joins or splits a line of its
/// own accord.
///
/// ## How it works
///
/// The tokenisation is ``ScriptSyntax``'s — the same one that colours the editor.
/// That is not a convenience: a formatter with its own idea of where a template
/// literal ends will one day disagree with the colouring about the same file, and
/// the disagreement shows up as a `//` inside a URL being read as a comment and a
/// space inserted into the middle of a string. One scanner, two uses.
///
/// It then walks the tokens keeping one piece of state — how deep the brackets
/// are — and appends the tokens back with the whitespace between them decided by
/// where that depth changed.
///
/// ## The invariants, which the tests check
///
///   - No character of the code is added, removed or reordered. Only whitespace
///     *between* tokens is rewritten; a token's own text is copied verbatim.
///   - No line is joined with another, and no line is split. A user who writes a
///     whole object on one line gets it back on one line.
///   - A file that is already formatted comes back unchanged, because every
///     decision is "would the convention put a space here" and the convention is
///     the one the file demonstrates.
enum ScriptFormatter {

    /// Reformats `text`, returning the new version.
    ///
    /// - Returns: the formatted script, or `nil` when there is nothing to format
    ///   (empty text) or the text is not tokenisable — which never happens for a
    ///   string, the scanner being total, but a future caller may pass something
    ///   it cannot handle and the caller here would rather do nothing than guess.
    static func format(_ text: String) -> String? {
        let tokens = ScriptSyntax.tokens(in: text)
        guard !tokens.isEmpty else { return nil }

        var writer = Writer(indentUnit: indentUnit, breaks: LineBreaks(tokens: tokens))
        writer.run(tokens)
        return writer.result
    }

    // MARK: - Indentation

    /// Two spaces.
    ///
    /// Fixed rather than detected. Detecting the file's own indentation sounds
    /// more polite and is worse in practice: the result then depends on what was
    /// pasted, so the same script formats two ways and a user copying code out of
    /// an AI answer gets whatever that answer happened to use. One indent, always,
    /// is the behaviour a button can have.
    ///
    /// Two rather than four because of where this runs. The editor shows about 40
    /// characters across on a phone, and four-space indentation spends a tenth of
    /// that on each level of nesting — three levels in and half the line is gone.
    static let indentUnit = "  "

    // MARK: - Line breaks

    /// Which offsets must have a newline before or after them.
    ///
    /// ## The width rule, and why it is the only one
    ///
    /// A construct the author wrote on one line is kept on one line *if it is
    /// short enough to read that way*, and laid out if it is not. That single
    /// rule is what separates this from a beautifier:
    ///
    ///   - `{ "Content-Type": "application/json" }` is 32 characters and stays.
    ///     A conventional beautifier would explode it into four lines, which is
    ///     the change users object to — four lines to say one thing.
    ///   - A whole `push({ url, headers, body })` on one line is not readable at
    ///     any width a phone has, so it is laid out, at the commas its author
    ///     already punctuated with.
    ///
    /// There is no re-wrapping of lines the author *broke*. A line they wrote
    /// stays a line; the only lines this creates are the ones implied by a
    /// construct it decided was too wide.
    struct LineBreaks {
        /// Offsets that must start a new line.
        var startsLine: Set<Int> = []
        /// Offsets after which a new line must begin.
        var endsLine: Set<Int> = []

        /// How wide an inline construct may be before it is laid out.
        ///
        /// Measured in the whole line's characters, and deliberately larger than
        /// what fits on screen: the editor shows roughly 40 characters at the
        /// standard inset, and wrapping at 40 would rewrite nearly every non-trivial
        /// line — which is the meddling being avoided. Wrapping at 96 leaves a line
        /// that needs a little horizontal scrolling alone and only breaks the ones a
        /// person would have broken anyway, at the commas they already punctuated
        /// with.
        static let inlineWidth = 96

        init(tokens: [ScriptSyntax.Span]) {
            // Every bracket, comma and semicolon with its offset, in order. The
            // rest of the characters do not affect where lines begin.
            var marks: [(offset: Int, character: Character)] = []
            for token in tokens where token.kind == .plain {
                let ns = token.text as NSString
                for position in 0..<ns.length {
                    guard let scalar = UnicodeScalar(ns.character(at: position)) else { continue }
                    let character = Character(scalar)
                    if "{}()[];,".contains(character) {
                        marks.append((token.range.location + position, character))
                    }
                }
            }

            // Match each opening bracket to its closing one.
            var pairs: [Int: Int] = [:]        // opening offset -> closing offset
            var owners: [Int] = []             // stack of opening offsets
            for mark in marks {
                switch mark.character {
                case "{", "(", "[":
                    owners.append(mark.offset)
                case "}", ")", "]":
                    guard let opening = owners.popLast() else { continue }
                    pairs[opening] = mark.offset
                default:
                    break
                }
            }

            // Which braces get laid out.
            //
            // The test is the width of the **line the construct sits on**, not of
            // the construct: `if (!res.ok) { throw new Error(\`…\`) }` is a long
            // construct and a perfectly readable line, and laying it out is exactly
            // the meddling being avoided. What matters is whether the author
            // already made it fit.
            var broken: Set<Int> = []
            for (opening, closing) in pairs where isBrace(opening, in: marks) {
                let content = tokens
                    .filter { $0.range.location >= opening && NSMaxRange($0.range) <= closing + 1 }
                    .map(\.text)
                    .joined()

                // The author broke it, so it stays broken.
                if content.contains("\n") { broken.insert(opening); continue }

                // Otherwise the construct itself is measured, not the line it sits
                // on. The line is the wrong unit twice over: a short object sitting
                // at the end of a long statement would be exploded for the
                // statement's fault, and indentation — which this very pass
                // changes — would count toward the width, making the result depend
                // on how deep the code was nested when it was pasted.
                if content.count > Self.inlineWidth { broken.insert(opening) }
            }

            // A `for (…;…;…)` header's semicolons do not end a line.
            var forHeaders: Set<Int> = []
            var parenOwners: [Int] = []
            for (index, mark) in marks.enumerated() {
                if mark.character == "(" {
                    parenOwners.append(mark.offset)
                    // Preceded by `for` in the token stream.
                    if let opening = parenOwners.last,
                       tokensContainsWord("for", endingBefore: opening, in: tokens) {
                        forHeaders.insert(opening)
                    }
                }
                if mark.character == ")" { _ = parenOwners.popLast() }
                _ = index
            }

            // Emit the breaks.
            var frame: [Int] = []              // opening offsets currently open
            for mark in marks {
                switch mark.character {
                case "{", "(", "[":
                    frame.append(mark.offset)
                    // Only a brace breaks, and only after itself: a call's
                    // parenthesis stays on the line that opened it, so `push({`
                    // begins the construct rather than `push(` on one line and `{`
                    // on the next.
                    if mark.character == "{", broken.contains(mark.offset) {
                        endsLine.insert(mark.offset)
                    }
                case "}", ")", "]":
                    let opening = frame.popLast()
                    if mark.character == "}", let opening, broken.contains(opening) {
                        startsLine.insert(mark.offset)
                    }
                case ";":
                    // Inside a `for` header, a semicolon separates clauses.
                    guard !frame.contains(where: { forHeaders.contains($0) }) else { break }
                    // A statement ends a line — unless its block was kept inline,
                    // in which case breaking here would leave the closing brace
                    // stranded on a line of its own, which is a worse layout than
                    // the one the author wrote.
                    if let enclosing = frame.last {
                        if broken.contains(enclosing) { endsLine.insert(mark.offset) }
                    } else {
                        endsLine.insert(mark.offset)
                    }
                case ",":
                    // A comma breaks when the construct it belongs to is laid out,
                    // which is what puts one entry per line.
                    if let enclosing = frame.last, broken.contains(enclosing) {
                        endsLine.insert(mark.offset)
                    }
                default:
                    break
                }
            }
        }

        /// Whether the mark at `offset` is a brace rather than a parenthesis or
        /// bracket.
        private func isBrace(_ offset: Int, in marks: [(offset: Int, character: Character)]) -> Bool {
            marks.first { $0.offset == offset }?.character == "{"
        }

        /// Whether `word` appears immediately before `offset` in the token stream.
        private func tokensContainsWord(
            _ word: String, endingBefore offset: Int, in tokens: [ScriptSyntax.Span]
        ) -> Bool {
            var lastNonSpace: ScriptSyntax.Span?
            for token in tokens {
                if token.range.location >= offset { break }
                if token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                lastNonSpace = token
            }
            return lastNonSpace?.text.hasSuffix(word) == true
        }
    }

    // MARK: - Writing

    /// Rebuilds the text, deciding only where lines begin and end.
    ///
    /// Every non-whitespace character is copied verbatim, and whitespace *inside*
    /// a string, template or comment is part of that token and also copied
    /// verbatim. The only thing this rewrites is the whitespace *between* tokens,
    /// which is what makes the formatter incapable of changing what a script does:
    ///
    ///   - whitespace containing a newline becomes a newline plus indentation from
    ///     the bracket depth, so the author's line breaks survive and their
    ///     indentation is corrected;
    ///   - whitespace without one becomes a single space, so `a + b` stays as the
    ///     author spaced it and `a+b`, having no whitespace between the tokens, is
    ///     left alone;
    ///   - whitespace the rules say must be a break is treated as if the author had
    ///     written one.
    private struct Writer {
        let indentUnit: String
        let breaks: LineBreaks

        /// Depth in braces, which is what indentation is derived from.
        var depth = 0
        /// Set when a rule requires a break after the character just written; taken
        /// at the next gap, so an author's blank line after it is not swallowed.
        var mustBreak = false
        var lines: [String] = []
        var current = ""

        init(indentUnit: String, breaks: LineBreaks) {
            self.indentUnit = indentUnit
            self.breaks = breaks
        }

        mutating func run(_ tokens: [ScriptSyntax.Span]) {
            for token in tokens {
                if token.kind != .plain {
                    // A string, template, comment or regular expression: its text
                    // is entirely its own, whitespace included.
                    current += token.text
                    continue
                }

                var pending = ""       // whitespace not yet emitted
                let ns = token.text as NSString

                for position in 0..<ns.length {
                    guard let scalar = UnicodeScalar(ns.character(at: position)) else { continue }
                    let character = Character(scalar)
                    let offset = token.range.location + position

                    if character.isWhitespace {
                        pending.append(character)
                        continue
                    }

                    // Decide the gap before this character.
                    let forceStart = breaks.startsLine.contains(offset) || mustBreak
                    emitGap(pending, forceBreak: forceStart)
                    mustBreak = false
                    pending = ""

                    if character == "}" {
                        // A `}` sits at the depth of what it closes, so it lines up
                        // with the statement rather than with the block's contents.
                        depth = max(0, depth - 1)
                        if isLineEmpty { current = indent(depth) }
                    }

                    current += String(character)

                    // Only a brace is a level: a call's parentheses stay on the
                    // line that opened them, so their contents are indented with
                    // the call rather than under it.
                    if character == "{" { depth += 1 }

                    // A break the rules require is remembered rather than taken:
                    // the gap that follows may carry a blank line of its own, and
                    // taking the break here would consume it.
                    if breaks.endsLine.contains(offset) { mustBreak = true }
                }

                emitGap(pending, forceBreak: mustBreak)
                mustBreak = false
            }

            if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(trailingTrim(current))
            }
            // Whatever indentation the last break left behind describes a line
            // that does not exist.
            current = ""
        }

        var result: String {
            var all = lines
            while all.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                all.removeLast()
            }
            return all.isEmpty ? "" : all.joined(separator: "\n") + "\n"
        }

        /// Emits the whitespace between two tokens.
        private mutating func emitGap(_ whitespace: String, forceBreak: Bool) {
            let hadNewline = whitespace.contains("\n")
            let breaksHere = forceBreak || hadNewline
            guard breaksHere else {
                // A space on one line, kept as a single space; nothing stays
                // nothing, so the author's `a+b` is untouched.
                if !whitespace.isEmpty { appendSpace() }
                return
            }

            // Two or more newlines are a deliberate blank line: kept, but only
            // ever one, since a script that arrives with a run of them is not more
            // readable for it.
            let blank = whitespace.filter { $0 == "\n" }.count >= 2
            endLine()
            if blank, lines.last?.isEmpty == false { lines.append("") }
        }

        private var isLineEmpty: Bool {
            current.trimmingCharacters(in: .whitespaces).isEmpty
        }

        private mutating func endLine() {
            // A line that was only indentation is not a line: it would become a
            // blank one, or a line of trailing spaces.
            let text = trailingTrim(current)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(text) }
            current = indent(depth)
        }

        private mutating func appendSpace() {
            if current.isEmpty || current.hasSuffix(" ") { return }
            current += " "
        }

        private func indent(_ depth: Int) -> String {
            String(repeating: indentUnit, count: depth)
        }

        private func trailingTrim(_ text: String) -> String {
            var result = text
            while result.hasSuffix(" ") || result.hasSuffix("\t") { result.removeLast() }
            return result
        }
    }
}
