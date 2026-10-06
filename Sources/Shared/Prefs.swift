import Foundation

/// A read-only, type-guarded view over a raw preference dictionary.
///
/// Preference plists are user-editable (and, on the log domain, written by an
/// older build), so a value at any key may be a type the caller does not
/// expect — an `NSString` where a number was meant, an `NSNull` where a
/// dictionary was meant, or nothing at all. Every accessor here therefore
/// guards the type and falls back to a default instead of trusting the cast.
///
/// Wrapping the dictionary means that policy lives in exactly one place, and
/// call sites read as `prefs.bool(Key.enabled)` instead of a chain of
/// `isKindOfClass:` checks.
public struct Prefs {
    public let raw: [String: Any]

    public init(_ raw: [String: Any]? = nil) {
        self.raw = raw ?? [:]
    }

    public var isEmpty: Bool { raw.isEmpty }
    public var keys: [String] { Array(raw.keys) }

    public subscript(key: String) -> Any? { raw[key] }

    // MARK: - Scalars

    /// `true`/`false` from a bool or a bool-ish string; `false` for anything
    /// else (including a missing key).
    public func bool(_ key: String) -> Bool {
        bool(key, default: false)
    }

    public func bool(_ key: String, default defaultValue: Bool) -> Bool {
        switch raw[key] {
        case let number as NSNumber: return number.boolValue
        case let string as String: return (string as NSString).boolValue
        default: return defaultValue
        }
    }

    /// Integer from a number, or from a string that parses leniently
    /// (`"12x"` becomes `12`). Non-numeric values yield `defaultValue`.
    public func int(_ key: String, default defaultValue: Int = 0) -> Int {
        switch raw[key] {
        case let number as NSNumber: return number.intValue
        case let string as String: return (string as NSString).integerValue
        default: return defaultValue
        }
    }

    /// Integer from a number, or from a string that is *entirely* numeric
    /// (`"12"`). A partial or non-numeric string (`"abc"`, `"12x"`) yields
    /// `nil` rather than silently parsing to `0`.
    public func strictInt(_ key: String) -> Int? {
        switch raw[key] {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let scanner = Scanner(string: trimmed)
            guard let value = scanner.scanInt(), scanner.isAtEnd else { return nil }
            return value
        default:
            return nil
        }
    }

    /// Strict integer whose "not configured" sentinels — an invalid value and
    /// the segment cell's `-1` — both resolve to `defaultValue`.
    public func resolvedInt(_ key: String, default defaultValue: Int) -> Int {
        guard let value = strictInt(key),
              value != segmentCellDefault else { return defaultValue }
        return value
    }

    public func double(_ key: String, default defaultValue: Double = 0) -> Double {
        switch raw[key] {
        case let number as NSNumber: return number.doubleValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return defaultValue }
            let scanner = Scanner(string: trimmed)
            guard let value = scanner.scanDouble(), scanner.isAtEnd else { return defaultValue }
            return value
        default:
            return defaultValue
        }
    }

    /// The value only when it is a `String`, otherwise `nil`.
    public func string(_ key: String) -> String? {
        raw[key] as? String
    }

    /// The value when it is a non-empty `String`, otherwise `defaultValue`.
    public func string(_ key: String, default defaultValue: String) -> String {
        guard let value = raw[key] as? String, !value.isEmpty else { return defaultValue }
        return value
    }

    /// The value when it is a `String`, otherwise `defaultValue`; an empty
    /// stored string counts as absent.
    public func nonEmptyString(_ key: String) -> String? {
        guard let value = raw[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Containers

    /// The value only when it is a dictionary, otherwise `nil`.
    public func dict(_ key: String) -> Prefs? {
        guard let value = raw[key] as? [String: Any] else { return nil }
        return Prefs(value)
    }

    /// The value as an array, or `[]`.
    public func array(_ key: String) -> [Any] {
        raw[key] as? [Any] ?? []
    }

    /// The value as an array of strings, skipping non-string entries.
    public func stringArray(_ key: String) -> [String] {
        array(key).compactMap { $0 as? String }
    }

    /// The value as an array of dictionaries, skipping malformed entries so a
    /// hand-edited plist can never crash the caller.
    public func dictionaries(_ key: String) -> [Prefs] {
        array(key).compactMap {
            guard let value = $0 as? [String: Any] else { return nil }
            return Prefs(value)
        }
    }

    /// Sub-entries of an array that are both a dictionary and `enabled`, with
    /// non-dictionary entries skipped.
    public func enabledDictionaries(_ key: String) -> [Prefs] {
        dictionaries(key).filter { $0.bool(PrefKey.enabled) }
    }

    /// Persistent identifiers of the enabled entries in an array
    /// (`[{ id: "x", enabled: true }]`).
    ///
    /// Devices and sounds are both stored this way in prefs — the *normalized*
    /// service config reduces sounds to a plain list of IDs, but the raw
    /// preference keeps the full entries so the picker can show them.
    public func enabledIdentifiers(_ key: String) -> [String] {
        dictionaries(key).compactMap { entry in
            guard entry.bool(PrefKey.enabled), let id = entry.string("id") else { return nil }
            return id
        }
    }
}

// MARK: - Building

extension Prefs {
    /// `Prefs` from a `[String: Any]?` that may actually hold anything
    /// (typically a value read straight out of a plist).
    public static func from(_ value: Any?) -> Prefs {
        Prefs(value as? [String: Any])
    }
}
