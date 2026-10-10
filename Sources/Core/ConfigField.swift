import Foundation

/// One setting a service declares for itself.
///
/// A script that posts to a chat service has a `key`; one that talks to a
/// self-hosted server has a `url` and maybe a `token`. Those are the service's
/// own vocabulary, and the app cannot know them in advance — so the service
/// declares them, and everything else follows from that:
///
/// - The **service** page is where they are declared: what they are called, how
///   they are grouped, what they default to.
/// - An **instance** page is where they are filled in: the same fields, one set
///   of values per instance, which is what makes two instances of one script two
///   destinations rather than two copies.
/// - A **script** reads them as `pref`, so the script never has to carry a key
///   of its own and two instances can share it.
///
/// The values live on the **instance** and the defaults live on the **service**,
/// and a default is a *seed*: it fills the fields in when an instance is created.
/// After that the instance owns its values — an instance that was never given one
/// reads `""` or `false`, not the default. So editing a default changes what the
/// *next* instance starts with and leaves existing instances exactly as they are,
/// which is what makes a default safe to fiddle with.
public struct ConfigField {

    /// How a field is edited.
    ///
    /// Two, deliberately. A text field and a switch cover what a push service
    /// actually needs — a URL, a token, a channel name, and a flag — and every
    /// further kind of control costs a cell, a validator and a decision about
    /// what "empty" means. A third can be added when a real service needs one.
    public enum Kind: String {
        case text
        case toggle

        /// The English name. A page localizes it before showing it: this file
        /// is in the Core layer, which the Preferences bundle's string table is
        /// not visible from.
        public var label: String {
            switch self {
            case .text: return "Text"
            case .toggle: return "Switch"
            }
        }
    }

    /// The name the script reads it by: `pref.<key>`.
    ///
    /// Also the storage key, and therefore stable — renaming it is how a script
    /// author breaks their own script, which is why the editor shows it as the
    /// one thing a field *has* to have.
    public var key: String

    /// The label on the field.
    public var title: String

    public var kind: Kind

    /// The section the field appears under, or empty for a group of its own.
    ///
    /// A group rather than a number: groups carry a heading and a footer, which
    /// is how the description travels, and a list that reorders by dragging must
    /// not encode position in the value.
    public var group: String

    /// The line under the group explaining what these fields are for.
    public var note: String

    /// What a new instance of this service is created with.
    ///
    /// A seed, not a fallback: it fills the field in on the instance page when
    /// the instance is made, and an instance that has no value reads `""` or
    /// `false` regardless of what this says.
    public var defaultValue: Any

    public init(
        key: String,
        title: String = "",
        kind: Kind = .text,
        group: String = "",
        note: String = "",
        defaultValue: Any = ""
    ) {
        self.key = key
        self.title = title
        self.kind = kind
        self.group = group
        self.note = note
        self.defaultValue = defaultValue
    }

    /// What to show as the field's name: its title, or its key when it has none.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? key : trimmed
    }

    public var defaultString: String {
        if let text = defaultValue as? String { return text }
        if let number = defaultValue as? NSNumber { return number.stringValue }
        return ""
    }

    public var defaultBool: Bool {
        if let value = defaultValue as? Bool { return value }
        if let number = defaultValue as? NSNumber { return number.boolValue }
        return (defaultValue as? String)?.isEmpty == false
    }

    // MARK: - Encoding

    init(stored: Prefs) {
        key = stored.string(ConfigFieldKey.key, default: "")
        title = stored.string(ConfigFieldKey.title, default: "")
        kind = Kind(rawValue: stored.string(ConfigFieldKey.kind, default: "text")) ?? .text
        group = stored.string(ConfigFieldKey.group, default: "")
        note = stored.string(ConfigFieldKey.note, default: "")
        defaultValue = stored[ConfigFieldKey.defaultValue] ?? ""
    }

    var encoded: [String: Any] {
        var object: [String: Any] = [
            ConfigFieldKey.key: key,
            ConfigFieldKey.kind: kind.rawValue,
            ConfigFieldKey.defaultValue: defaultValue,
        ]
        // Empty strings are dropped rather than stored empty, so a definition
        // that never used a title does not pin one forever.
        if !title.isEmpty { object[ConfigFieldKey.title] = title }
        if !group.isEmpty { object[ConfigFieldKey.group] = group }
        if !note.isEmpty { object[ConfigFieldKey.note] = note }
        return object
    }

    /// Whether a key may be read as `pref.<key>`.
    ///
    /// Checked rather than escaped: a script author writes `pref.apiKey`, so the
    /// name has to be an identifier, and quietly rewriting what they typed would
    /// make the script and the page disagree about the name.
    public static func isValidKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return false }
        guard let first = trimmed.first, first.isLetter || first == "_" else { return false }
        return trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// The keys a script cannot have, because they are already in its scope.
    ///
    /// A field called `push` would shadow the function the script sends with,
    /// and the failure would look like a broken script rather than a bad name.
    public static let reservedKeys: Set<String> = [
        "push", "bullet", "device", "pref", "fetch", "localStorage", "console",
        "keep", "globalThis", "this", "arguments", "eval", "undefined", "null",
        "true", "false", "let", "const", "var", "function", "return", "await",
        "async", "class", "new", "typeof", "instanceof", "in", "of", "delete",
        "if", "else", "for", "while", "do", "switch", "case", "break", "continue",
        "try", "catch", "finally", "throw", "with", "yield", "static", "super",
        "extends", "import", "export",
    ]

    /// Why a key cannot be used, or `nil` when it can.
    ///
    /// An enum rather than a message: this is the Core layer, which has no
    /// string table, and the page that shows the reason is the one that can
    /// word it.
    public enum KeyProblem {
        case isEmpty
        case isNotAnIdentifier
        case isReserved(String)
    }

    public static func keyProblem(_ key: String) -> KeyProblem? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .isEmpty }
        if !isValidKey(trimmed) { return .isNotAnIdentifier }
        if reservedKeys.contains(trimmed) { return .isReserved(trimmed) }
        return nil
    }

    /// A key that is free, based on `base`.
    public static func uniqueKey(basedOn base: String = "field", taken: [String]) -> String {
        let used = Set(taken)
        guard used.contains(base) else { return base }
        var index = 2
        while used.contains("\(base)\(index)") { index += 1 }
        return "\(base)\(index)"
    }
}

/// The storage keys of one config field's own object.
public enum ConfigFieldKey {
    public static let key = "key"
    public static let title = "title"
    public static let kind = "kind"
    public static let group = "group"
    public static let note = "note"
    public static let defaultValue = "defaultValue"
}

// MARK: - Reading a service's declarations

/// The config fields a service declares, and the values an instance holds.
///
/// Reads and writes go through here rather than being spelled out at each call
/// site, because three places need the same answer in the same shape: the
/// service page (declaring), the instance page (filling in), and the script
/// (reading as `pref`).
public enum ConfigFields {

    // MARK: Renaming and deleting values

    /// Moves every instance's value from one key to another.
    ///
    /// A renamed field would otherwise appear cleared on every service of the
    /// type, which reads as data loss even though the value is still stored under
    /// the old name.
    public static func renameValue(from old: String, to new: String, forDefinition id: String) {
        guard !old.isEmpty, !new.isEmpty, old != new else { return }
        for instance in ServiceInstanceStore.instances() where instance.type == id {
            PrefsStore.updateInstance(instance.id) { object in
                guard var values = object[PrefKey.configValues] as? [String: Any],
                      let value = values[old] else { return }
                values.removeValue(forKey: old)
                values[new] = value
                object[PrefKey.configValues] = values
            }
        }
    }

    /// Removes every instance's value for a key that is no longer declared.
    ///
    /// Without this a service that re-declared the same name would silently
    /// inherit values nobody could see or clear, since the field that showed them
    /// is gone.
    public static func forgetValues(ofKey key: String, forDefinition id: String) {
        guard !key.isEmpty else { return }
        for instance in ServiceInstanceStore.instances() where instance.type == id {
            PrefsStore.updateInstance(instance.id) { object in
                guard var values = object[PrefKey.configValues] as? [String: Any] else { return }
                values.removeValue(forKey: key)
                if values.isEmpty {
                    object.removeValue(forKey: PrefKey.configValues)
                } else {
                    object[PrefKey.configValues] = values
                }
            }
        }
    }

    // MARK: Declarations

    /// The fields a service declares, in the order the user arranged them.
    public static func declared(byDefinition id: String) -> [ConfigField] {
        guard !id.isEmpty else { return [] }
        return CustomServiceStore.rawEntry(id: id)
            .dictionaries(PrefKey.configFields)
            .map(ConfigField.init(stored:))
    }

    /// Replaces a service's declarations.
    public static func setDeclared(_ fields: [ConfigField], forDefinition id: String) {
        CustomServiceStore.update(id: id) { object in
            if fields.isEmpty {
                object.removeValue(forKey: PrefKey.configFields)
            } else {
                object[PrefKey.configFields] = fields.map(\.encoded)
            }
        }
    }

    // MARK: Values recovered without a declaration

    /// The fields an instance's stored values imply, when the service that
    /// declared them no longer exists.
    ///
    /// This is what is left after a service is deleted: the values are still on
    /// the instance — deliberately, so they can be carried to another service —
    /// but the declarations that named and grouped them are gone with the service.
    /// A page built from the declarations would therefore show nothing at all,
    /// which reads as the settings having been lost.
    ///
    /// So the fields are reconstructed from the values themselves: the storage key
    /// becomes the label, and the *kind* of the value says whether it was a switch
    /// or a text field. What cannot be recovered is the human title, the group and
    /// the note — those were only ever written down in the declaration — so a
    /// field shows its key, which is also the name the script read it by and so
    /// still means something to whoever wrote it.
    public static func savedFields(forInstance id: String) -> [ConfigField] {
        guard !id.isEmpty else { return [] }
        let stored = PrefsStore.instance(id).dict(PrefKey.configValues) ?? Prefs()
        // Sorted, not in storage order: a dictionary has none, so any order would
        // be arbitrary — and arbitrary is the one thing a settings page must not
        // be, since it would put the fields somewhere different after a relaunch.
        return stored.raw.keys.sorted().compactMap { key in
            guard !key.isEmpty else { return nil }
            let value = stored[key]
            let isSwitch = value is NSNumber || value is Bool
            return ConfigField(
                key: key,
                title: key,
                kind: isSwitch ? .toggle : .text,
                group: "",
                note: "",
                defaultValue: isSwitch ? false : ""
            )
        }
    }

    // MARK: Values

    /// What an instance holds for each field, as the script reads it.
    ///
    /// Every declared field appears, so a script reading `pref.key` always gets
    /// a value of the right type rather than `undefined` — but an instance that
    /// never set one reads `""` or `false`. The declaration's default is *not*
    /// consulted here: it was applied when the instance was created, and after
    /// that the instance's own values are the answer.
    public static func values(forInstance id: String, type: String) -> [String: Any] {
        let declared = self.declared(byDefinition: type)
        guard !declared.isEmpty else { return [:] }
        let stored = PrefsStore.instance(id).dict(PrefKey.configValues) ?? Prefs()

        var values: [String: Any] = [:]
        for field in declared {
            guard !field.key.isEmpty else { continue }
            switch field.kind {
            case .toggle:
                values[field.key] = stored[field.key].map {
                    Prefs([field.key: $0]).bool(field.key)
                } ?? false
            case .text:
                values[field.key] = stored.string(field.key) ?? ""
            }
        }
        return values
    }

    /// The values a **new** instance of this service starts with.
    ///
    /// Read off the declarations, so creating a service fills in the fields the
    /// author gave a default to and leaves the rest empty.
    public static func seedValues(forDefinition id: String) -> [String: Any] {
        var values: [String: Any] = [:]
        for field in declared(byDefinition: id) {
            guard !field.key.isEmpty else { continue }
            switch field.kind {
            case .toggle:
                if field.defaultBool { values[field.key] = true }
            case .text:
                if !field.defaultString.isEmpty { values[field.key] = field.defaultString }
            }
        }
        return values
    }

    /// Stores one field's value on an instance.
    ///
    /// An empty text field and an off switch are *removed* rather than stored,
    /// which is the same thing they read as: the store then holds only what was
    /// actually filled in, so a preference file says at a glance which fields
    /// this instance was given.
    public static func setValue(_ value: Any?, forKey key: String, onInstance id: String) {
        guard !key.isEmpty, !id.isEmpty else { return }

        // Decided by the value's *type*, not by trying each type in turn.
        //
        // A switch and a text field both arrive as `Any`, and asking one of them
        // the other's question gets a wrong answer rather than no answer: a
        // boolean cast to `String` fails, and if that failure is read as "not a
        // string, therefore empty" then *every* boolean looks unset — so turning
        // a switch on stored nothing and it sprang back off. `NSNumber` first,
        // because that is what a `PSSwitchCell` sends.
        let isUnset: Bool
        if let number = value as? NSNumber {
            // Any number other than zero counts as on, which is how a switch
            // reads its own stored value.
            isUnset = number.doubleValue == 0
        } else if let flag = value as? Bool {
            isUnset = !flag
        } else if let text = value as? String {
            isUnset = text.isEmpty
        } else {
            isUnset = value == nil
        }

        PrefsStore.updateInstance(id) { object in
            var values = (object[PrefKey.configValues] as? [String: Any]) ?? [:]
            if isUnset {
                values.removeValue(forKey: key)
            } else if let value {
                values[key] = value
            }
            if values.isEmpty {
                object.removeValue(forKey: PrefKey.configValues)
            } else {
                object[PrefKey.configValues] = values
            }
        }
    }

    /// The fields grouped for display, preserving declaration order.
    ///
    /// Ungrouped fields come first, because a service that uses no groups should
    /// read as a plain list; the rest follow in the order their first field
    /// appeared, and a field's own position is what puts it in its group.
    public static func grouped(_ fields: [ConfigField]) -> [(name: String, note: String, fields: [ConfigField])] {
        var order: [String] = []
        var buckets: [String: [ConfigField]] = [:]
        for field in fields {
            let name = field.group
            if buckets[name] == nil {
                order.append(name)
                buckets[name] = []
            }
            buckets[name]?.append(field)
        }
        return order.map { name in
            let members = buckets[name] ?? []
            // The group's note is the first non-empty one: several fields in a
            // group may repeat it, and the heading only needs it once.
            let note = members.first { !$0.note.isEmpty }?.note ?? ""
            return (name: name, note: note, fields: members)
        }
    }
}
