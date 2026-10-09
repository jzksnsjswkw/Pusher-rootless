import Foundation

/// The portable form of a configuration: two arrays, read and written by hand.
///
/// ## Why two arrays
///
/// A *service* here is a script the user wrote — a new kind of destination — and
/// an *instance* is one configured use of a kind. They are different things with
/// different lifetimes: a script can be written before anything uses it and can
/// outlive every instance that did, and one script normally has several instances.
/// So they travel as separate lists, and an instance refers to its script by
/// name:
///
/// ```json
/// {
///   "services":  [ { "name": "My Bark", "script": "push({ url })" } ],
///   "instances": [ { "name": "Phone",  "service": "My Bark", "values": { … } } ]
/// }
/// ```
///
/// A single script therefore appears exactly once no matter how many instances
/// use it, and the file reads the way the two pages are laid out.
///
/// ## What does not travel
///
/// Nothing that is only true of one device: no instance identifiers, no logs, no
/// a script's `localStorage`, no cached tokens. Those are the parts that would
/// make a configuration imported on a second phone be subtly the first phone's —
/// claiming the old one's history, or sending with a credential nobody typed
/// there.
public struct ServiceExport {

    /// The document format's version, so a future change can be recognised rather
    /// than misread. Refused when it is newer than this build understands.
    public static let currentVersion = 1

    public var version: Int
    public var kind: String
    public var exportedAt: String

    /// The scripts: the kinds of destination the user defined.
    public var services: [ExportedService]

    /// The configured destinations.
    public var instances: [ExportedInstance]

    public init(services: [ExportedService] = [], instances: [ExportedInstance] = []) {
        self.version = Self.currentVersion
        self.kind = Self.documentKind
        self.exportedAt = ISO8601DateFormatter().string(from: Date())
        self.services = services
        self.instances = instances
    }

    public static let documentKind = "com.noahsaso.pusher.services"

    /// How many things the document carries, for a one-line description.
    public var count: Int { services.count + instances.count }

    // MARK: - A script

    /// One service: the user's own kind of destination, carried whole.
    public struct ExportedService {
        /// What the user calls it. An instance refers to its script by this name,
        /// which is also why the name is required: a script with no name could
        /// not be referred to.
        public var name: String

        public var script: String

        /// The settings it declares, so an instance's ``ExportedInstance/values``
        /// have something to be keyed by on the far side.
        public var configFields: [[String: Any]]?

        /// Its own payload and run options, which its instances inherit.
        public var defaults: [String: Any]?

        public init(
            name: String,
            script: String,
            configFields: [[String: Any]]? = nil,
            defaults: [String: Any]? = nil
        ) {
            self.name = name
            self.script = script
            self.configFields = configFields
            self.defaults = defaults
        }
    }

    // MARK: - An instance

    /// One configured destination.
    public struct ExportedInstance {
        /// What the user calls it.
        public var name: String

        /// The built-in kind, for an instance of one (`"Pushover"`, `"Bark"`, …).
        /// `nil` when the instance uses a script.
        public var type: String?

        /// The name of the script this instance uses, matching a ``ExportedService``
        /// by name. `nil` for a built-in kind.
        public var service: String?

        /// Whether it was switched on here.
        public var enabled: Bool

        /// The rest of its settings, keyed as the app stores them.
        public var settings: [String: Any]?

        /// The values it filled into its service's declared settings, keyed by
        /// the setting's name.
        public var values: [String: Any]?

        /// The apps its filter applies to, and which direction it reads in, when
        /// the user set one.
        public var appList: [String]?
        public var appListIsBlacklist: Bool?

        public init(
            name: String,
            type: String? = nil,
            service: String? = nil,
            enabled: Bool = true,
            settings: [String: Any]? = nil,
            values: [String: Any]? = nil,
            appList: [String]? = nil,
            appListIsBlacklist: Bool? = nil
        ) {
            self.name = name
            self.type = type
            self.service = service
            self.enabled = enabled
            self.settings = settings
            self.values = values
            self.appList = appList
            self.appListIsBlacklist = appListIsBlacklist
        }
    }
}

// MARK: - Fields that belong to the device

/// The keys that describe *this* device rather than the configuration.
///
/// Dropped on export and ignored on import, because they are state rather than
/// settings. Importing a container's id or a log would make the new instance
/// claim the old one's history; importing a cached WeChat token would make it
/// send with a credential the user did not type here; importing a script's
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

    /// Keys that never travel on a script: its own identity, which is per-device,
    /// and the settings it declares, which are written as their own field.
    static let serviceKeys: Set<String> = [
        PrefKey.instanceID,
        PrefKey.instanceName,
        PrefKey.script,
        PrefKey.configFields,
    ]

    public static func shouldExportServiceKey(_ key: String) -> Bool {
        !serviceKeys.contains(key)
    }
}
