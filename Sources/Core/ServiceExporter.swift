import Foundation

/// Reading and writing the export document.
///
/// Separate from the document's shape because the two change for different
/// reasons: the shape is a promise to other versions and other people, the codec
/// is this build's answer to the stored layout. When the stored layout moves —
/// which it is free to, being the app's own business — only the codec changes.
public enum ServiceExporter {

    // MARK: - Export

    /// Builds the document for the given instances.
    ///
    /// - Parameter ids: which instances to export, in the order the lists show
    ///   them, so the document reads in the order the user sees.
    public static func document(instanceIDs ids: [String]) -> ServiceExport {
        let definitions = Dictionary(
            uniqueKeysWithValues: CustomServiceStore.definitions().map { ($0.id, $0) }
        )
        var services: [ServiceExport.ExportedService] = []

        for id in ids {
            guard let instance = ServiceInstanceStore.instances().first(where: { $0.id == id })
            else { continue }
            services.append(export(instance: instance, definitions: definitions))
        }
        return ServiceExport(services: services)
    }

    /// Builds the document for every instance.
    public static func documentForAllInstances() -> ServiceExport {
        document(instanceIDs: ServiceInstanceStore.instances().map(\.id))
    }

    private static func export(
        instance: ServiceInstance,
        definitions: [String: CustomServiceDefinition]
    ) -> ServiceExport.ExportedService {
        let raw = instance.config.raw

        // A script service travels with its script: the type is a user's own
        // work, and an import on another device has nothing to resolve it by.
        var definition: ServiceExport.ExportedDefinition?
        if let source = definitions[instance.type] {
            var stored = CustomServiceStore.rawEntry(id: source.id).raw
            stored.removeValue(forKey: PrefKey.instanceID)
            stored.removeValue(forKey: PrefKey.instanceName)
            stored.removeValue(forKey: PrefKey.script)
            if let icon = stored[PrefKey.customIcon] as? String,
               let image = ServiceIcon.image(fromBase64: icon) {
                stored[PrefKey.customIcon] = ServiceIcon.storedValue(image)
            }
            definition = ServiceExport.ExportedDefinition(
                name: source.name,
                script: source.script,
                configFields: ConfigFields.declared(byDefinition: source.id).map(\.encoded),
                defaults: stored
            )
        }

        // Everything the instance holds that is configuration, minus identity
        // and per-app overrides (which are their own structure and are exported
        // part of `settings` only for the top level).
        var settings = raw
            .filter { ServiceExportFilter.shouldExportInstanceKey($0.key) }
            .filter { $0.key != PrefKey.appList && $0.key != PrefKey.appListIsBlacklist }
            .filter { $0.key != PrefKey.configValues }

        // An icon written before the palette encoder existed is stored as 32-bit
        // RGBA and is several times the size of the same picture now. Re-encoded
        // here, on the way out: a document someone pastes into a message should
        // carry the compact form, and rewriting what is already on disk for no
        // reason the user asked for would be a worse trade.
        if let stored = settings[PrefKey.customIcon] as? String,
           let image = ServiceIcon.image(fromBase64: stored) {
            settings[PrefKey.customIcon] = ServiceIcon.storedValue(image)
        }

        // The declared settings' values, which are what the user typed into the
        // service's own fields.
        let values = Prefs(raw).dict(PrefKey.configValues)?.raw

        // The app list is lifted out because it is the one setting that is a list
        // of identifiers rather than a scalar, and keeping it at the top level
        // makes the document readable.
        let appList = Prefs(raw).array(PrefKey.appList).compactMap { $0 as? String }

        return ServiceExport.ExportedService(
            name: instance.name,
            type: definition == nil ? instance.type : nil,
            definition: definition,
            enabled: instance.isEnabled,
            settings: settings.isEmpty ? nil : settings,
            values: (values?.isEmpty == false) ? values : nil,
            appList: appList.isEmpty ? nil : appList,
            appListIsBlacklist: raw[PrefKey.appListIsBlacklist] as? Bool
        )
    }

    // MARK: - Encoding

    /// The document as pretty-printed JSON text.
    ///
    /// Sorted keys and newlines: the file is meant to be readable, and in
    /// practice someone will look at it — to check what a secret contains before
    /// sending it to a friend, or to fix a script by hand.
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
        ]
        object["services"] = document.services.map(encode(service:))
        return object
    }

    private static func encode(service: ServiceExport.ExportedService) -> [String: Any] {
        var object: [String: Any] = [
            "name": service.name,
            "enabled": service.enabled,
        ]
        if let type = service.type { object["type"] = type }
        if let definition = service.definition {
            var encoded: [String: Any] = [
                "name": definition.name,
                "script": definition.script,
            ]
            if let fields = definition.configFields { encoded["configFields"] = fields }
            if let defaults = definition.defaults { encoded["defaults"] = defaults }
            object["definition"] = encoded
        }
        if let settings = service.settings { object["settings"] = settings }
        if let values = service.values { object["values"] = values }
        if let appList = service.appList { object["appList"] = appList }
        if let isBlacklist = service.appListIsBlacklist {
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
            // A bare array of services is accepted: it is what someone editing
            // the file by hand most plausibly produces.
            if let services = object as? [[String: Any]] {
                return ServiceExport(services: services.compactMap(decode(service:)))
            }
            throw ServiceImportError.malformed("The document is not a JSON object")
        }

        if let kind = root["kind"] as? String, kind != ServiceExport.documentKind {
            throw ServiceImportError.notAnExport(kind)
        }
        if let version = root["version"] as? Int, version > ServiceExport.currentVersion {
            throw ServiceImportError.tooNew(version, ServiceExport.currentVersion)
        }

        guard let rawServices = root["services"] as? [[String: Any]] else {
            throw ServiceImportError.malformed("The document has no services in it")
        }
        let services = rawServices.compactMap(decode(service:))
        guard !services.isEmpty else {
            throw ServiceImportError.malformed("The document has no usable services in it")
        }

        var document = ServiceExport(services: services)
        document.version = (root["version"] as? Int) ?? ServiceExport.currentVersion
        document.kind = (root["kind"] as? String) ?? ServiceExport.documentKind
        document.exportedAt = (root["exportedAt"] as? String) ?? ""
        return document
    }

    /// Reads one service, or `nil` when it lacks what it needs to be one.
    ///
    /// Forgiving on purpose: a hand-edited file may have dropped an optional
    /// field, and refusing the whole document because one entry is incomplete
    /// would make the format unpleasant to work with. A service with no name and
    /// no type is the only thing that cannot be used.
    private static func decode(service raw: [String: Any]) -> ServiceExport.ExportedService? {
        let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (raw["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var definition: ServiceExport.ExportedDefinition?
        if let rawDefinition = raw["definition"] as? [String: Any] {
            let script = rawDefinition["script"] as? String ?? ""
            let definitionName = (rawDefinition["name"] as? String) ?? type ?? "Service"
            definition = ServiceExport.ExportedDefinition(
                name: definitionName,
                script: script,
                configFields: rawDefinition["configFields"] as? [[String: Any]],
                defaults: rawDefinition["defaults"] as? [String: Any]
            )
        }

        guard let resolvedName = name, !resolvedName.isEmpty else { return nil }
        guard (type?.isEmpty == false) || definition != nil else { return nil }

        return ServiceExport.ExportedService(
            name: resolvedName,
            type: type?.isEmpty == true ? nil : type,
            definition: definition,
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
    /// Every service in the document already exists here, by type and name.
    case nothingToAdd([String])

    public var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            return detail
        case .notAnExport(let kind):
            return "This is a \"\(kind)\" file, not a Pusher services export."
        case .tooNew(let version, let supported):
            return "This export was made by a newer version of Pusher "
                + "(format \(version)); this one reads up to \(supported)."
        case .nothingToAdd(let names):
            return "Nothing was added: this device already has "
                + names.joined(separator: ", ") + "."
        }
    }

    /// The Core layer has no string table, so pages word these themselves; this
    /// is the English text a page falls back to.
    public var englishDescription: String { errorDescription ?? "Import failed" }
}
