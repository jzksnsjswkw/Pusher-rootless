import Foundation

/// Reading and writing the export document.
///
/// Separate from the document's shape because the two change for different
/// reasons: the shape is a promise to other versions and other people, the codec
/// is this build's answer to the stored layout. When the stored layout moves —
/// which it is free to, being the app's own business — only the codec changes.
public enum ServiceExporter {

    // MARK: - What to include

    /// Which parts of the configuration a document should carry.
    ///
    /// Both flags rather than one, because the two are genuinely separable
    /// intentions: "send my destinations to a friend who already has the script"
    /// and "send my script to a friend who will configure it themselves" are both
    /// ordinary things to want, and neither implies the other.
    public struct Selection {
        /// The configured destinations chosen.
        public var instanceIDs: [String]
        /// The scripts chosen.
        public var serviceIDs: [String]

        public init(instanceIDs: [String] = [], serviceIDs: [String] = []) {
            self.instanceIDs = instanceIDs
            self.serviceIDs = serviceIDs
        }

        public var isEmpty: Bool { instanceIDs.isEmpty && serviceIDs.isEmpty }
    }

    /// Builds the document for a selection.
    ///
    /// The set of scripts is the chosen ones **plus any a chosen instance uses**.
    /// An instance without its script has nothing to send through, so carrying
    /// one and not the other would produce a document that cannot be used — and a
    /// document is written to be used. Only the *scripts* are ever added this way;
    /// an instance is never added because a script was chosen, since a script has
    /// no destinations of its own.
    public static func document(selection: Selection) -> ServiceExport {
        let definitions = Dictionary(
            uniqueKeysWithValues: CustomServiceStore.definitions().map { ($0.id, $0) }
        )

        // The ids given are honoured as given. An instance whose service is not
        // also chosen is written without it, and the importer will find the
        // service on the receiving device or say that it is missing — which is
        // the point of the switch: a recipient who already has the service should
        // not be sent a second copy of it.
        let instanceIDs = selection.instanceIDs.filter { id in
            ServiceInstanceStore.instances().contains { $0.id == id }
        }
        let serviceIDs = selection.serviceIDs

        // In the order the Services page shows them, so the document reads the way
        // the page does rather than in the order ids happened to be collected.
        let orderedServices = CustomServiceStore.definitions()
            .filter { serviceIDs.contains($0.id) }
            .map { export(service: $0) }

        let orderedInstances = ServiceInstanceStore.instances()
            .filter { instanceIDs.contains($0.id) }
            .map { export(instance: $0, definitions: definitions) }

        return ServiceExport(services: orderedServices, instances: orderedInstances)
    }

    /// Everything configured, both kinds.
    public static func documentForEverything() -> ServiceExport {
        document(selection: Selection(
            instanceIDs: ServiceInstanceStore.instances().map(\.id),
            serviceIDs: CustomServiceStore.definitions().map(\.id)
        ))
    }

    // MARK: - One service

    /// A script, carried whole.
    static func export(service source: CustomServiceDefinition) -> ServiceExport.ExportedService {
        var stored = CustomServiceStore.rawEntry(id: source.id).raw
        for key in ServiceExportFilter.serviceKeys { stored.removeValue(forKey: key) }
        // An icon written before the palette encoder existed is 32-bit RGBA and
        // several times the size of the same picture now. Re-encoded here, on the
        // way out: a document someone pastes into a message should carry the
        // compact form.
        if let icon = stored[PrefKey.customIcon] as? String,
           let image = ServiceIcon.image(fromBase64: icon) {
            stored[PrefKey.customIcon] = ServiceIcon.storedValue(image)
        }

        return ServiceExport.ExportedService(
            name: source.name,
            script: source.script,
            configFields: ConfigFields.declared(byDefinition: source.id).map(\.encoded),
            defaults: stored
        )
    }

    // MARK: - One instance

    private static func export(
        instance: ServiceInstance,
        definitions: [String: CustomServiceDefinition]
    ) -> ServiceExport.ExportedInstance {
        let prefs = Prefs(instance.config.raw)
        let script = definitions[instance.type]

        // Everything the instance holds that is configuration. The app list and
        // the declared settings' values are lifted out below into their own
        // fields, so they are excluded here rather than written twice.
        var settings = instance.config.raw
            .filter { ServiceExportFilter.shouldExportInstanceKey($0.key) }
            .filter { $0.key != PrefKey.appList && $0.key != PrefKey.appListIsBlacklist }
            .filter { $0.key != PrefKey.configValues }

        if let stored = settings[PrefKey.customIcon] as? String,
           let image = ServiceIcon.image(fromBase64: stored) {
            settings[PrefKey.customIcon] = ServiceIcon.storedValue(image)
        }

        let values = prefs.dict(PrefKey.configValues)?.raw
        let appList = prefs.array(PrefKey.appList).compactMap { $0 as? String }

        return ServiceExport.ExportedInstance(
            name: instance.name,
            // A script instance is named by its script rather than by its type,
            // which is a per-device id and means nothing on the far side.
            type: script == nil ? instance.type : nil,
            service: script?.name,
            enabled: instance.isEnabled,
            settings: settings.isEmpty ? nil : settings,
            values: (values?.isEmpty == false) ? values : nil,
            appList: appList.isEmpty ? nil : appList,
            appListIsBlacklist: instance.config.raw[PrefKey.appListIsBlacklist] as? Bool
        )
    }

    // MARK: - Encoding

    /// The document as pretty-printed JSON text.
    ///
    /// Sorted keys and newlines: the file is meant to be readable, and in practice
    /// someone will look at it — to check what a secret contains before sending it
    /// to a friend, or to fix a script by hand.
    public static func json(from document: ServiceExport) throws -> String {
        let object = encode(document)
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw ServiceImportError.malformed("The document is not valid UTF-8")
        }
        return text
    }

    private static func encode(_ document: ServiceExport) -> [String: Any] {
        var object: [String: Any] = [
            "version": document.version,
            "kind": document.kind,
            "exportedAt": document.exportedAt,
            "services": document.services.map(encode(service:)),
            "instances": document.instances.map(encode(instance:)),
        ]
        object["exportedAt"] = document.exportedAt
        return object
    }

    private static func encode(service: ServiceExport.ExportedService) -> [String: Any] {
        var object: [String: Any] = [
            "name": service.name,
            "script": service.script,
        ]
        if let fields = service.configFields { object["configFields"] = fields }
        if let defaults = service.defaults { object["defaults"] = defaults }
        return object
    }

    private static func encode(instance: ServiceExport.ExportedInstance) -> [String: Any] {
        var object: [String: Any] = [
            "name": instance.name,
            "enabled": instance.enabled,
        ]
        if let type = instance.type { object["type"] = type }
        if let service = instance.service { object["service"] = service }
        if let settings = instance.settings { object["settings"] = settings }
        if let values = instance.values { object["values"] = values }
        if let appList = instance.appList { object["appList"] = appList }
        if let isBlacklist = instance.appListIsBlacklist {
            object["appListIsBlacklist"] = isBlacklist
        }
        return object
    }

    // MARK: - Decoding

    /// Reads a document from JSON text.
    public static func document(fromJSON text: String) throws -> ServiceExport {
        guard let data = text.data(using: .utf8) else {
            throw ServiceImportError.malformed("The text is not valid UTF-8")
        }
        return try document(from: data)
    }

    public static func document(from data: Data) throws -> ServiceExport {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ServiceImportError.malformed(
                "This is not readable as JSON (\(error.localizedDescription)). "
                    + "Check that the whole document was copied."
            )
        }
        guard let root = object as? [String: Any] else {
            throw ServiceImportError.malformed("The document is not a JSON object")
        }

        if let kind = root["kind"] as? String, kind != ServiceExport.documentKind {
            throw ServiceImportError.notAnExport(kind)
        }
        if let version = root["version"] as? Int, version > ServiceExport.currentVersion {
            throw ServiceImportError.tooNew(version, ServiceExport.currentVersion)
        }

        let services = (root["services"] as? [[String: Any]] ?? [])
            .compactMap(decode(service:))
        let instances = (root["instances"] as? [[String: Any]] ?? [])
            .compactMap(decode(instance:))

        guard !services.isEmpty || !instances.isEmpty else {
            throw ServiceImportError.malformed("The document has no usable services in it")
        }

        var document = ServiceExport(services: services, instances: instances)
        document.version = (root["version"] as? Int) ?? ServiceExport.currentVersion
        document.kind = (root["kind"] as? String) ?? ServiceExport.documentKind
        document.exportedAt = (root["exportedAt"] as? String) ?? ""
        return document
    }

    /// Reads one script, or `nil` when it lacks what it needs to be one.
    ///
    /// Forgiving on purpose: a hand-edited file may have dropped an optional
    /// field, and refusing the whole document because one entry is incomplete
    /// would make the format unpleasant to work with. A script needs a name — an
    /// instance refers to it by name — and a body.
    private static func decode(service raw: [String: Any]) -> ServiceExport.ExportedService? {
        guard let name = (raw["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
            let script = raw["script"] as? String
        else { return nil }

        return ServiceExport.ExportedService(
            name: name,
            script: script,
            configFields: raw["configFields"] as? [[String: Any]],
            defaults: raw["defaults"] as? [String: Any]
        )
    }

    /// Reads one instance, or `nil` when it lacks what it needs to be one.
    ///
    /// An instance needs a name and something to send through: either a built-in
    /// type or the name of a script the document carries.
    private static func decode(instance raw: [String: Any]) -> ServiceExport.ExportedInstance? {
        guard let name = (raw["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }

        let type = (raw["type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let service = (raw["service"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard (type?.isEmpty == false) || (service?.isEmpty == false) else { return nil }

        return ServiceExport.ExportedInstance(
            name: name,
            type: type?.isEmpty == true ? nil : type,
            service: service?.isEmpty == true ? nil : service,
            enabled: (raw["enabled"] as? NSNumber)?.boolValue
                ?? (raw["enabled"] as? Bool) ?? true,
            settings: raw["settings"] as? [String: Any],
            values: raw["values"] as? [String: Any],
            appList: (raw["appList"] as? [Any])?.compactMap { $0 as? String },
            appListIsBlacklist: (raw["appListIsBlacklist"] as? NSNumber)?.boolValue
                ?? (raw["appListIsBlacklist"] as? Bool)
        )
    }
}

/// Why an import could not be read, or could not be applied.
public enum ServiceImportError: LocalizedError {
    case malformed(String)
    case notAnExport(String)
    case tooNew(Int, Int)
    /// An instance refers to a script the document does not carry.
    case missingService(String, String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            return detail
        case .notAnExport(let kind):
            return "This is a \"\(kind)\" file, not a Pusher services export."
        case .tooNew(let version, let supported):
            return "This export was made by a newer version of Pusher "
                + "(format \(version)); this one reads up to \(supported)."
        case .missingService(let instance, let service):
            return "\"\(instance)\" uses a service called \"\(service)\", which the "
                + "document does not include."
        }
    }
}
