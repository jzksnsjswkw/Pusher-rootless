import UIKit

/// Puts an exported document back into this device's configuration.
///
/// The import is *additive*: it never overwrites or deletes what is already
/// here. That is the only defensible default for a file a user may have been
/// given, or may have exported from this very device — an import that replaced
/// an existing service would be indistinguishable from a loss, and one that
/// silently merged two services' settings would leave a configuration nobody
/// chose. A name that is taken becomes "Name 2", which is visible immediately and
/// reversible by renaming.
public enum ServiceImporter {

    /// What an import did, so the page can say it.
    public struct Result {
        /// The names of the services that were added, in order.
        public var added: [String]
        /// The names that had to be changed to avoid a collision, as
        /// `(imported, used)`.
        public var renamed: [(from: String, to: String)]
        /// The names of the scripts that were added.
        public var definitions: [String]
        /// Services or scripts that were already present and skipped.
        public var skipped: [String]

        public var summary: String {
            var parts: [String] = []
            if !definitions.isEmpty { parts.append("added \(definitions.count) scripts") }
            if !added.isEmpty { parts.append("added \(added.count)") }
            if !skipped.isEmpty { parts.append("skipped \(skipped.count) already here") }
            if !renamed.isEmpty { parts.append("renamed \(renamed.count) to avoid a clash") }
            return parts.isEmpty ? "nothing to do" : parts.joined(separator: ", ")
        }
    }

    // MARK: - Applying

    /// Adds every service in the document.
    ///
    /// - Parameter makeDefinition: creates a script type from an exported
    ///   definition and returns its new id. Injected so the Core layer does not
    ///   have to know how definitions are stored; the default does the obvious
    ///   thing.
    public static func apply(_ document: ServiceExport) throws -> Result {
        try apply(document, makeDefinition: createDefinition)
    }

    /// Same, with the definition factory injected, so the Core layer can be
    /// exercised without touching stored definitions.
    static func apply(
        _ document: ServiceExport,
        makeDefinition: (ServiceExport.ExportedDefinition) -> String?
    ) throws -> Result {
        var result = Result(added: [], renamed: [], definitions: [], skipped: [])

        // Definitions are created once per exported name, since two instances of
        // one script must end up referencing *one* definition rather than two
        // copies — otherwise editing the script later would only affect one of
        // them.
        var definitionsByKey: [String: String] = [:]

        // The scripts the document carries on their own, first — so a service
        // that also references one is resolved against it instead of making a
        // second copy.
        for definition in document.definitions {
            let key = definition.name.lowercased()
            guard definitionsByKey[key] == nil else { continue }

            // One already here under the same name *and* the same script is the
            // same definition, so importing it again would duplicate it. The
            // script is compared as well as the name because a name is chosen
            // freely, and two different scripts may well share one.
            if let existing = CustomServiceStore.definitions().first(where: {
                $0.name.lowercased() == key && $0.script == definition.script
            }) {
                definitionsByKey[key] = existing.id
                result.skipped.append(definition.name)
                continue
            }

            guard let created = makeDefinition(definition) else {
                result.skipped.append(definition.name)
                continue
            }
            definitionsByKey[key] = created
            result.definitions.append(
                CustomServiceStore.definition(id: created)?.name ?? definition.name
            )
        }

        for service in document.services {
            // An instance already here under the same type and name is the same
            // service, so importing it again would be a duplicate rather than a
            // restore. Compared by type *and* name because two Pushovers are
            // normally two destinations.
            let typeKey = service.definition.map { "script:\($0.name)" } ?? (service.type ?? "")
            if isAlreadyPresent(typeKey: typeKey, name: service.name, definition: service.definition) {
                result.skipped.append(service.name)
                continue
            }

            var resolvedType = service.type ?? ServiceRegistry.customServiceName
            if let definition = service.definition {
                let key = definition.name.lowercased()
                if let existing = definitionsByKey[key] {
                    resolvedType = existing
                } else if let created = makeDefinition(definition) {
                    definitionsByKey[key] = created
                    resolvedType = created
                    // Reported as well: a script the user gets without being told
                    // is a script they will find on the Services page later and
                    // not know where it came from.
                    result.definitions.append(
                        CustomServiceStore.definition(id: created)?.name ?? definition.name
                    )
                } else {
                    // A definition that could not be created leaves its instance
                    // with nothing to send through, so it is skipped rather than
                    // imported as a webhook with no URL.
                    result.skipped.append(service.name)
                    continue
                }
            }

            // A name that is taken is changed rather than refused: the user
            // asked for this service to be here, and a suffix is what the add
            // flow does in the same situation.
            let name = uniqueInstanceName(service.name)

            let instance = ServiceInstanceStore.add(type: resolvedType, name: name)
            apply(service, to: instance.id)
            if name != service.name {
                result.renamed.append((from: service.name, to: name))
            }
            result.added.append(name)
        }

        guard !result.added.isEmpty || !result.definitions.isEmpty || !result.skipped.isEmpty
        else {
            throw ServiceImportError.malformed("The document has no services in it")
        }
        return result
    }

    /// Writes one service's settings onto the instance that was just created.
    private static func apply(_ service: ServiceExport.ExportedService, to id: String) {
        PrefsStore.updateInstance(id) { object in
            // The instance was created with the type's defaults; the document's
            // own values are layered on top, so a field the document does not
            // mention keeps what the type would have given it.
            if let settings = service.settings {
                for (key, value) in settings where ServiceExportFilter.shouldExportInstanceKey(key) {
                    object[key] = value
                }
            }
            if let appList = service.appList, !appList.isEmpty {
                object[PrefKey.appList] = appList
                object[PrefKey.appListIsBlacklist] = service.appListIsBlacklist ?? true
            } else if service.appListIsBlacklist != nil {
                object[PrefKey.appListIsBlacklist] = service.appListIsBlacklist
            }
            // The declared settings' values, in the instance's own namespace, so
            // a document cannot reach a framework key through them.
            if let values = service.values, !values.isEmpty {
                object[PrefKey.configValues] = values
            }
            object[PrefKey.serviceEnabled] = service.enabled
        }
    }

    /// The icon a document says a service carries, or `nil` when it carries none.
    ///
    /// Read from the document rather than from what is stored here: the preview
    /// describes what is *in the file*, and showing this device's existing logo
    /// would be describing the wrong thing. The bundled artwork, which lives in
    /// the Preferences layer, is left to the caller to fall back to.
    public static func storedIcon(for service: ServiceExport.ExportedService) -> UIImage? {
        if let base64 = service.settings?[PrefKey.customIcon] as? String,
           let image = ServiceIcon.image(fromBase64: base64) {
            return image
        }
        if let base64 = service.definition?.defaults?[PrefKey.customIcon] as? String {
            return ServiceIcon.image(fromBase64: base64)
        }
        return nil
    }

    // MARK: - Definitions

    /// Creates a script type from an exported definition.
    private static func createDefinition(_ exported: ServiceExport.ExportedDefinition) -> String? {
        let definition = CustomServiceDefinition(
            id: CustomServiceDefinition.makeID(),
            name: CustomServiceStore.uniqueName(basedOn: exported.name),
            script: exported.script
        )
        CustomServiceStore.save(definition)

        var defaults = exported.defaults ?? [:]
        // The identity and script belong to the definition that was just made,
        // not to whatever the document carried, so they cannot be overwritten by
        // a hand-edited file.
        defaults.removeValue(forKey: PrefKey.instanceID)
        defaults.removeValue(forKey: PrefKey.instanceName)
        defaults.removeValue(forKey: PrefKey.script)
        if let fields = exported.configFields {
            defaults[PrefKey.configFields] = fields
        }

        CustomServiceStore.update(id: definition.id) { object in
            for (key, value) in defaults where ServiceExportFilter.shouldExportDefinitionKey(key) {
                object[key] = value
            }
            // Written last and whole: the declarations are the field list the
            // instance page and the script's `pref` are both built from, so a
            // partial write of them would be worse than none.
            if let fields = exported.configFields, !fields.isEmpty {
                object[PrefKey.configFields] = fields
            } else {
                object.removeValue(forKey: PrefKey.configFields)
            }
        }
        return definition.id
    }

    /// Whether this service is already configured here, so the import can skip
    /// it instead of adding a duplicate.
    private static func isAlreadyPresent(
        typeKey: String,
        name: String,
        definition: ServiceExport.ExportedDefinition?
    ) -> Bool {
        let instances = ServiceInstanceStore.instances()
        let folded = name.lowercased()

        if let definition {
            // A script: the same *script* under the same name is the same
            // service, whatever its type id is here — which is the point, since
            // the id is per-device and a re-import would otherwise duplicate.
            let byName = CustomServiceStore.definitions().first {
                $0.name.lowercased() == definition.name.lowercased()
                    && $0.script == definition.script
            }
            guard let byName else { return false }
            return instances.contains {
                $0.type == byName.id && $0.name.lowercased() == folded
            }
        }

        return instances.contains {
            $0.type == typeKey && $0.name.lowercased() == folded
        }
    }

    /// The instance name to use, suffixing to avoid a collision.
    private static func uniqueInstanceName(_ name: String) -> String {
        guard !ServiceInstanceStore.isNameAvailable(name) else { return name }
        var index = 2
        while !ServiceInstanceStore.isNameAvailable("\(name) \(index)") { index += 1 }
        return "\(name) \(index)"
    }
}
