import Foundation

/// Says what is wrong with a regular expression, not just that something is.
///
/// `NSRegularExpression` reports every failure the same way — "the value is
/// invalid" — because ICU's own error code is discarded on the way up. That is
/// useless for what this is for: a rule that cannot compile matches nothing, and
/// the user has to be told which character stopped it and why.
///
/// So the pattern is compiled through ICU directly, where the status code and the
/// failing offset are both available. ICU is a system library on every iOS version
/// this runs on; `uregex_open` is reached through `dlsym` for the same reason the
/// other private entry points in this project are — it is not in a public header,
/// but it is in the binary and it is what `NSRegularExpression` itself calls.
enum RegexDiagnosis {

    /// What is wrong with a pattern, as a localization key.
    ///
    /// When ICU reported a position the key is followed by `|<offset>`, so the page
    /// can render "… (position 9)". The key-and-number shape is here because this
    /// layer cannot see the string table, and a sentence assembled here could not be
    /// translated.
    ///
    /// - Parameter pattern: the expression as typed.
    /// - Returns: a key, or `nil` when the pattern compiles.
    static func problem(with pattern: String) -> String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Compiled with the same options the matcher uses, so a pattern that works
        // there cannot be reported here.
        if (try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])) != nil {
            return nil
        }
        guard let failure = icuFailure(for: trimmed) else {
            return "Not a valid regular expression."
        }

        // The offset counts UTF-16 units, which is one per character for the ASCII
        // a pattern is written in; for anything else it is close enough to point at
        // the right place.
        // The sentence is returned as a key with its offset appended: the Core layer
        // cannot see the bundle's string table, so the page translates it.
        let sentence = key(for: failure.status)
        return failure.offset > 0 ? sentence + "|\(failure.offset)" : sentence
    }

    // MARK: - ICU

    /// The status and offset ICU reports for a pattern, or `nil` if the library
    /// could not be reached.
    private static func icuFailure(for pattern: String) -> (status: Int32, offset: Int)? {
        guard let open = uregexOpen else { return nil }

        var status: Int32 = 0
        let units = Array(pattern.utf16)

        // ICU's `UParseError` is `{ int32 line; int32 offset; UChar preContext[16];
        // UChar postContext[16]; }`. A Swift struct with arrays in it has no
        // guaranteed layout, so the buffer is allocated by size and the offset read
        // at its known position — the two contexts after it are never touched.
        var parse = [UInt8](repeating: 0, count: 8 + 128)

        let handle: UnsafeMutableRawPointer? = units.withUnsafeBufferPointer { buffer in
            parse.withUnsafeMutableBytes { raw in
                open(buffer.baseAddress, Int32(units.count), 0,
                     raw.baseAddress, &status)
            }
        }
        if let handle { uregexClose?(handle) }
        let offset = parse.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }
        return (status: status, offset: Int(offset))
    }

    private typealias URegexOpenSignature = @convention(c) (
        UnsafeRawPointer?, Int32, UInt32, UnsafeMutableRawPointer?,
        UnsafeMutablePointer<Int32>?
    ) -> UnsafeMutableRawPointer?

    private typealias URegexCloseSignature = @convention(c) (
        UnsafeMutableRawPointer?
    ) -> Void

    private static let library = dlopen("/usr/lib/libicucore.dylib", RTLD_NOW)

    private static let uregexOpen: URegexOpenSignature? = {
        guard let library, let symbol = dlsym(library, "uregex_open") else { return nil }
        return unsafeBitCast(symbol, to: URegexOpenSignature.self)
    }()

    private static let uregexClose: URegexCloseSignature? = {
        guard let library, let symbol = dlsym(library, "uregex_close") else { return nil }
        return unsafeBitCast(symbol, to: URegexCloseSignature.self)
    }()

    /// ICU's `URegularExpressionErrorCode`, in the words a reader needs.
    ///
    /// Named by hand rather than looked up: the codes are a published, frozen part
    /// of ICU's ABI, and a table of the ones a person can actually type is more use
    /// than a number.
    static func key(for status: Int32) -> String {
        switch status {
        case 66304: return "Internal error in the regular expression engine."
        case 66305: return "Syntax error in the regular expression."
        case 66306: return "The regular expression is too big."
        case 66307: return "Invalid escape sequence."
        case 66308: return "Invalid character range."
        case 66309: return "Memory exhausted."
        case 66310: return "Missing closing parenthesis."
        case 66311: return "Invalid property name."
        case 66312: return "Invalid named capture group."
        case 66313: return "Invalid character class."
        case 66314: return "Invalid group reference."
        case 66315: return "Octal escape too large."
        case 66316: return "Look-behind is not supported by this expression."
        case 66317: return "Invalid back reference."
        case 66319: return "Missing closing bracket."
        case 66320: return "Invalid character range."
        case 66321: return "Stack overflow."
        case 66322: return "Time limit exceeded."
        default: return "Not a valid regular expression."
        }
    }
}
