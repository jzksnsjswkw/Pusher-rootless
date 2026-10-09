import Foundation

/// The portable form of a service: what travels to another device.
///
/// Plain JSON, and plain *data* — a definition's declared settings, an
/// instance's filled-in values, a script's source. Nothing that is only true of
/// one device goes in: no instance identifiers, no logs, no local storage, no
/// cached tokens. Those are the parts that would make importing on a second
/// phone produce a service that is subtly the first phone's.
///
/// The shape is meant to be read and edited by hand, since that is most of the
/// point of exporting something as JSON: an array of objects with obvious key
/// names, pretty-printed, rather than an opaque blob.
public struct ServiceExport {

    /// The document format's version, so a future change can be recognised
    /// rather than misread. Refused when it is newer than this build understands.
    public static let currentVersion = 1

    public var version: Int
    public var kind: String
    public var exportedAt: String

    /// The configured destinations.
    public var services: [ExportedService]

    /// Scripts that are being moved on their own, with no destination yet.
    ///
    /// A separate array rather than an instance-shaped entry, because that is what
    /// the user picked: a service definition is a thing in its own right — it
    /// appears on its own page, can be written before anything uses it, and can
    /// outlive every instance that referenced it. Folding it into `services`
    /// would mean importing it as a destination nobody asked for.
    public var definitions: [ExportedDefinition]

    public init(
        services: [ExportedService],
        definitions: [ExportedDefinition] = []
    ) {
        self.version = Self.currentVersion
        self.kind = Self.documentKind
        self.exportedAt = ISO8601DateFormatter().string(from: Date())
        self.services = services
        self.definitions = definitions
    }

    /// How many things the document carries, for a one-line description.
    public var count: Int { services.count + definitions.count }

    public static let documentKind = "com.noahsaso.pusher.services"

    // MARK: - One exported service

    /// One service: the type if the user wrote it, the configured destination,
    /// and that destination's filled-in settings.
    public struct ExportedService {
        /// The service's own name, which is what the user recognises it by.
        public var name: String

        /// The type it is, for a built-in service (`"Pushover"`, `"Bark"`, …).
        /// `nil` for a script the user wrote, which travels in ``definition``.
        public var type: String?

        /// The script service this instance uses, when it uses one.
        public var definition: ExportedDefinition?

        /// Whether the instance was switched on here.
        public var enabled: Bool

        /// The non-secret settings of a built-in service as its descriptor
        /// normalizes them, so importing restores what the page shows.
        public var settings: [String: Any]?

        /// The values this instance filled into its service's declared settings,
        /// keyed by the setting's name.
        public var values: [String: Any]?

        /// The apps this instance's filter applies to, and which direction it
        /// reads in, when the user set one.
        public var appList: [String]?
        public var appListIsBlacklist: Bool?

        public init(
            name: String,
            type: String? = nil,
            definition: ExportedDefinition? = nil,
            enabled: Bool = true,
            settings: [String: Any]? = nil,
            values: [String: Any]? = nil,
            appList: [String]? = nil,
            appListIsBlacklist: Bool? = nil
        ) {
            self.name = name
            self.type = type
            self.definition = definition
            self.enabled = enabled
            self.settings = settings
            self.values = values
            self.appList = appList
            self.appListIsBlacklist = appListIsBlacklist
        }
    }

    /// A script the user wrote, carried whole.
    public struct ExportedDefinition {
        public var name: String
        public var script: String
        /// The source definition's id, used only while building a document so one
        /// script referenced by several instances is written once. Never read on
        /// import: a new device gives the definition its own id.
        public var sourceID: String?
        /// The settings it declares, so the importer can recreate the fields an
        /// instance's ``ExportedService/values`` are keyed by.
        public var configFields: [[String: Any]]?
        /// Its own payload options and run options, which its instances inherit.
        public var defaults: [String: Any]?

        public init(
            name: String,
            script: String,
            sourceID: String? = nil,
            configFields: [[String: Any]]? = nil,
            defaults: [String: Any]? = nil
        ) {
            self.name = name
            self.script = script
            self.sourceID = sourceID
            self.configFields = configFields
            self.defaults = defaults
        }
    }
}

// MARK: - Fields that belong to the device

/// The keys that describe *this* device rather than the service.
///
/// Dropped on export and ignored on import, because they are state rather than
/// configuration. Importing a container's id or a log would make the new service
/// claim the old one's history; importing a cached WeChat token would make it
/// send with a credential the user did not type here; importing a service's
/// `localStorage` would carry one device's memory of a conversation into
/// another's.
public enum ServiceExportFilter {
    /// Instance keys that describe this device: identity, logs, caches.
    static let instanceKeys: Set<String> = [
        PrefKey.instanceID,          // a new instance gets a new id
        PrefKey.customApps,          // per-app overrides are re-added by hand
        PrefKey.scriptStorage,       // one device's memory, not a setting
        PrefKey.hookStorage,
        "wechatToken", "accessToken", "tokenExpiry", "wechatTokenExpiry",
    ]

    /// Suffixes that mark a per-service key as this device's log rather than its
    /// configuration, whatever the instance is called.
    static let instanceKeySuffixes = ["LogEnabled"]

    /// Whether a stored instance key should travel.
    public static func shouldExportInstanceKey(_ key: String) -> Bool {
        if instanceKeys.contains(key) { return false }
        // A log's enable flag is keyed by the instance's *name*
        // (`<name>LogEnabled`), which is also user-editable — so it is matched by
        // its suffix rather than by a list of names.
        return !instanceKeySuffixes.contains { key.hasSuffix($0) }
    }

    /// The definition keys that are this device's, filtered the same way.
    static let definitionKeys: Set<String> = []

    public static func shouldExportDefinitionKey(_ key: String) -> Bool {
        !definitionKeys.contains(key)
    }
}
