import Foundation

/// A service type the user defined by writing a script.
///
/// This is the "custom" half of the configuration: a *type*, not a configured
/// destination. Writing one — "a Bark that posts to my own server", say — makes
/// a new kind of service that then behaves exactly like a built-in one: it can be
/// added to the service list, enabled, given an app list and a log, and added
/// more than once with different settings.
///
/// The split matters because the two halves answer different questions. A
/// definition says *how* to send somewhere; a service instance says *where* to
/// send and whether to. Defining a type once and referencing it many times is
/// what makes a script worth writing.
public struct CustomServiceDefinition {
    /// Stable identifier, and the value an instance's `type` holds.
    ///
    /// Prefixed so it can never collide with a built-in service's registry name
    /// (`"Bark"`, `"Pushover"`, …), which is what lets ``ServiceRegistry`` resolve
    /// both kinds through one lookup.
    public let id: String

    /// The user-visible label, shown in the service list and the add-type list.
    public var name: String

    /// The user's JavaScript.
    public var script: String

    /// The wordings of one definition's own fields, so its settings page can be
    /// built without the user having to describe a schema.
    public var descriptionText: String

    public init(id: String, name: String, script: String, descriptionText: String = "") {
        self.id = id
        self.name = name
        self.script = script
        self.descriptionText = descriptionText
    }

    /// A fresh identifier.
    public static func makeID() -> String { "script:" + UUID().uuidString }
}

// MARK: - Storage

/// Reading and writing the `CustomServices` array.
///
/// Definitions are stored as a plain array of objects, like the instances they
/// are referenced by, so the whole configuration is two lists that are edited the
/// same way.
public enum CustomServiceStore {
    /// Every definition, in the order the user arranged them.
    public static func definitions() -> [CustomServiceDefinition] {
        PrefsStore.prefs().dictionaries(PrefKey.customServices).compactMap { raw -> CustomServiceDefinition? in
            guard let id = raw.nonEmptyString(PrefKey.instanceID) else { return nil }
            return CustomServiceDefinition(
                id: id,
                name: raw.nonEmptyString(PrefKey.instanceName)
                    ?? "Custom Service",
                script: raw.string(PrefKey.script, default: ""),
                descriptionText: raw.string(PrefKey.serviceDescription, default: "")
            )
        }
    }

    /// The definition with this id, or `nil` when it has been deleted.
    public static func definition(id: String) -> CustomServiceDefinition? {
        definitions().first { $0.id == id }
    }

    /// A definition that is not in use, for the add list's default name.
    public static func uniqueName(basedOn base: String = "Custom Service") -> String {
        let taken = Set(definitions().map(\.name))
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    /// Whether a name is free.
    public static func isNameAvailable(_ name: String, excluding id: String? = nil) -> Bool {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty else { return false }
        return !definitions().contains {
            $0.id != id && $0.name.lowercased() == candidate
        }
    }

    /// Writes one definition's identity and script, adding it when it is new.
    ///
    /// A **merge into** the stored object, not a replacement of it. A definition
    /// carries far more than the four fields this struct names — its logo, its
    /// payload options, its run options, the settings it declares — and those
    /// live on the stored object alone. Replacing it with an encoding of the
    /// struct would therefore delete everything the struct does not mention, and
    /// the deletion would be invisible until someone opened the page that reads
    /// them.
    ///
    /// The identity fields are still written unconditionally: this is how a
    /// rename and a script edit are saved, and both are the struct's own values.
    public static func save(_ definition: CustomServiceDefinition, notify: Bool = true) {
        var stored = rawDefinitions()
        var fields = encode(definition)
        // A description is only overwritten when the struct carries one, so
        // saving a script does not clear a description that arrived another way.
        if definition.descriptionText.isEmpty {
            fields.removeValue(forKey: PrefKey.serviceDescription)
        }

        if let index = stored.firstIndex(where: {
            Prefs($0).nonEmptyString(PrefKey.instanceID) == definition.id
        }) {
            for (key, value) in fields { stored[index][key] = value }
        } else {
            stored.append(fields)
        }
        setDefinitions(stored, notify: notify)
    }

    /// Creates a definition and returns it.
    @discardableResult
    public static func add(name: String? = nil) -> CustomServiceDefinition {
        let definition = CustomServiceDefinition(
            id: CustomServiceDefinition.makeID(),
            name: name ?? uniqueName(),
            script: Self.starterScript
        )
        save(definition)
        return definition
    }

    /// Merge fields into one definition's stored object.
    ///
    /// The run options the definition page edits (share-context/thread, timeout,
    /// response cap) are stored on the definition itself, next to the payload
    /// options, and every instance of the type seeds from them.
    public static func update(id: String, notify: Bool = true, _ mutate: (inout [String: Any]) -> Void) {
        guard !id.isEmpty else { return }
        var stored = rawDefinitions()
        guard let index = stored.firstIndex(where: {
            Prefs($0).nonEmptyString(PrefKey.instanceID) == id
        }) else { return }
        mutate(&stored[index])
        setDefinitions(stored, notify: notify)
    }

    /// The raw stored object of one definition, for reads the typed struct does
    /// not carry.
    public static func rawEntry(id: String) -> Prefs {
        guard !id.isEmpty else { return Prefs() }
        return rawDefinitions()
            .first { Prefs($0).nonEmptyString(PrefKey.instanceID) == id }
            .map(Prefs.init) ?? Prefs()
    }

    /// The payload options a definition holds, as the defaults its services start
    /// with.
    ///
    /// They are stored on the definition object itself (which is what the
    /// definition page's cells write to), so they are read out of the raw entry.
    static func definitionPrefs(_ definition: CustomServiceDefinition) -> [String: Any] {
        guard let stored = rawDefinitions().first(where: {
            Prefs($0).nonEmptyString(PrefKey.instanceID) == definition.id
        }) else { return [:] }

        // Only the payload fields are defaults; the identity and script are not
        // something an instance would override.
        let keys = [
            PrefKey.includeIcon, PrefKey.includeImage,
            PrefKey.imageMaxWidth, PrefKey.imageMaxHeight, PrefKey.imageShrinkFactor,
            PrefKey.dateFormat,
            // The icon travels with the payload options because it is one of
            // them: a script that posts to a chat account has an icon of its own,
            // and every instance of it should start with that icon.
            PrefKey.customIcon, PrefKey.customIconSymbol, PrefKey.customIconTint,
            PrefKey.customIconSource, PrefKey.customIconSize,
        ]
        return keys.reduce(into: [:]) { result, key in
            if let value = stored[key] { result[key] = value }
        }
    }

    /// Writes the definitions back in the given order, which is how a reorder is
    /// persisted: `save` keeps each entry's place, so the list itself has to be
    /// replaced to change the order.
    public static func reorder(_ definitions: [CustomServiceDefinition]) {
        setDefinitions(definitions.map(encode))
    }

    /// Deletes a definition.
    ///
    /// Instances that referenced it are left alone: their type no longer
    /// resolves, and ``ServiceRegistry`` falls back to the generic webhook, so a
    /// deleted script turns its services into plain webhooks rather than making
    /// them vanish or fail to send.
    public static func remove(id: String) {
        var stored = rawDefinitions()
        stored.removeAll { Prefs($0).nonEmptyString(PrefKey.instanceID) == id }
        setDefinitions(stored)
    }

    /// How many service instances reference a definition.
    public static func usageCount(of id: String) -> Int {
        ServiceInstanceStore.instances().filter { $0.type == id }.count
    }

    // MARK: - Raw

    private static func rawDefinitions() -> [[String: Any]] {
        PrefsStore.prefs().dictionaries(PrefKey.customServices).map(\.raw)
    }

    private static func setDefinitions(_ definitions: [[String: Any]], notify: Bool = true) {
        PrefsStore.setValue(definitions, forKey: PrefKey.customServices, notify: notify)
    }

    private static func encode(_ definition: CustomServiceDefinition) -> [String: Any] {
        [
            PrefKey.instanceID: definition.id,
            PrefKey.instanceName: definition.name,
            PrefKey.script: definition.script,
            PrefKey.serviceDescription: definition.descriptionText,
        ]
    }

    /// The script a new definition starts with.
    ///
    /// A working one, so the first thing the user sees is the shape of a script
    /// rather than an empty editor.
    static let starterScript = """
    // This script defines a service. It runs for every notification and
    // decides what to send by calling push().
    //
    // bullet.title, bullet.message, bullet.appName, bullet.appID, bullet.date,
    // bullet.icon, bullet.image — the notification.
    //
    // fetch(url, init) sends a request; localStorage remembers values between
    // runs; console.log() writes to this service's log.

    push({
        url: "https://example.com/notify",
        method: "POST",
        headers: {
            "Content-Type": "application/json"
        },
        body: {
            title: bullet.title,
            message: bullet.message,
            app: bullet.appName
        }
    });
    """
}
