import Foundation

/// Puts an exported document back into this device's configuration.
///
/// The import is *additive*: it never overwrites or deletes what is already
/// here. That is the only defensible default for a file a user may have been
/// given, or may have exported from this very device — an import that replaced an
/// existing service would be indistinguishable from a loss, and one that silently
/// merged two services' settings would leave a configuration nobody chose. A name
/// that is taken becomes "Name 2", which is visible immediately and reversible by
/// renaming.
public enum ServiceImporter {

    /// What an import did, so the page can say it.
    public struct Result {
        /// The names of the services — the scripts — that were added.
        public var services: [String]
        /// The names of the instances that were added.
        public var instances: [String]
        /// The names that had to be changed to avoid a collision, as
        /// `(imported, used)`.
        public var renamed: [(from: String, to: String)]
        /// Entries that were not added, with the reason. Structured rather than
        /// as text, because this is the Core layer and has no string table — the
        /// page that shows the reason is the one that can word it.
        public var skipped: [Skipped]

        public var added: [String] { services + instances }

        /// Whether anything was written.
        public var isEmpty: Bool { services.isEmpty && instances.isEmpty }
    }

    /// One entry the import left out.
    public struct Skipped {
        public enum Reason {
            /// The same entry is already configured here.
            case alreadyPresent
            /// A script with no body, which could never send anything.
            case emptyScript
            /// An instance whose service is neither in the document nor here.
            case serviceMissing(String)
        }

        public let name: String
        public let reason: Reason

        public init(name: String, reason: Reason) {
            self.name = name
            self.reason = reason
        }
    }

    // MARK: - Applying

    /// Adds everything in the document.
    public static func apply(_ document: ServiceExport) throws -> Result {
        var result = Result(services: [], instances: [], renamed: [], skipped: [])

        // By name, since that is how an instance refers to its script in the
        // document. The scripts go first: an instance is resolved against this
        // map, so a document that carries both arrives with the instance already
        // pointing at its script.
        var definitionsByName: [String: String] = [:]

        for service in document.services {
            let key = service.name.lowercased()

            // One already here under the same name *and* the same script is the
            // same service, so importing it again would duplicate it. The script
            // is compared as well as the name because a name is chosen freely and
            // two different scripts may well share one.
            if let existing = CustomServiceStore.definitions().first(where: {
                $0.name.lowercased() == key && $0.script == service.script
            }) {
                definitionsByName[key] = existing.id
                result.skipped.append(Skipped(name: service.name, reason: .alreadyPresent))
                continue
            }

            if let created = create(service) {
                definitionsByName[key] = created
                result.services.append(CustomServiceStore.definition(id: created)?.name
                    ?? service.name)
            } else {
                result.skipped.append(Skipped(name: service.name, reason: .emptyScript))
            }
        }

        // A script already on this device by name, for a document that carries
        // instances but not their scripts — the case where "include services" was
        // turned off on export because the recipient already has them.
        func resolve(_ name: String) -> String? {
            if let known = definitionsByName[name.lowercased()] { return known }
            return CustomServiceStore.definitions()
                .first { $0.name.lowercased() == name.lowercased() }?
                .id
        }

        for instance in document.instances {
            let type: String
            if let serviceName = instance.service {
                guard let resolved = resolve(serviceName) else {
                    // The document names a script it does not carry and this
                    // device does not have, so the instance has nothing to send
                    // through. Skipped with the reason rather than imported as a
                    // webhook with no URL.
                    result.skipped.append(Skipped(
                        name: instance.name, reason: .serviceMissing(serviceName)
                    ))
                    continue
                }
                type = resolved
            } else if let builtIn = instance.type {
                type = builtIn
            } else {
                continue
            }

            // Compared by the kind it uses *and* its name: two Pushovers are
            // normally two destinations, but the same Pushover under the same
            // name is the same one.
            if isAlreadyPresent(type: type, name: instance.name) {
                result.skipped.append(Skipped(name: instance.name, reason: .alreadyPresent))
                continue
            }

            // A name that is taken is changed rather than refused: the user asked
            // for this instance to be here, and a suffix is what the add flow does
            // in the same situation.
            let name = uniqueInstanceName(instance.name)
            let created = ServiceInstanceStore.add(type: type, name: name)
            write(instance, to: created.id)
            if name != instance.name {
                result.renamed.append((from: instance.name, to: name))
            }
            result.instances.append(name)
        }

        guard !result.isEmpty || !result.skipped.isEmpty else {
            throw ServiceImportError.malformed("The document has no services in it")
        }
        return result
    }

    /// The keys an imported instance never takes from the document, whatever it
    /// says: they are written from the resolution above, so a document cannot
    /// point an instance at the exporting device's service or rename it over a
    /// name clash that was already avoided.
    private static let nonTransferableKeys: Set<String> = [
        PrefKey.instanceID, PrefKey.instanceType, PrefKey.instanceName,
        PrefKey.serviceEnabled,
    ]

    /// Writes one instance's settings onto the instance that was just created.
    private static func write(_ instance: ServiceExport.ExportedInstance, to id: String) {
        PrefsStore.updateInstance(id) { object in
            // The instance was created with the type's defaults; the document's
            // own values are layered on top, so a setting the document does not
            // mention keeps what the type would have given it.
            if let settings = instance.settings {
                for (key, value) in settings
                where ServiceExportFilter.shouldExportInstanceKey(key)
                    && !nonTransferableKeys.contains(key) {
                    object[key] = value
                }
            }
            if let appList = instance.appList, !appList.isEmpty {
                object[PrefKey.appList] = appList
                object[PrefKey.appListIsBlacklist] = instance.appListIsBlacklist ?? true
            } else if instance.appListIsBlacklist != nil {
                object[PrefKey.appListIsBlacklist] = instance.appListIsBlacklist
            }
            // The declared settings' values, in the instance's own namespace, so a
            // document cannot reach a framework key through them.
            if let values = instance.values, !values.isEmpty {
                object[PrefKey.configValues] = values
            }
            // `enabled` is identity, not a setting: written through the store's
            // own setter rather than through a settings closure, which drops
            // identity keys on purpose (see `ServiceInstanceStore.update`).
        }
        ServiceInstanceStore.setEnabled(id, instance.enabled)
    }

    // MARK: - Creating a script

    /// Creates a script from an exported service, returning its new id.
    ///
    /// - Returns: `nil` when the script has nothing in it, since a service with
    ///   no body could never send anything.
    private static func create(_ exported: ServiceExport.ExportedService) -> String? {
        guard !exported.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let definition = CustomServiceDefinition(
            id: CustomServiceDefinition.makeID(),
            name: CustomServiceStore.uniqueName(basedOn: exported.name),
            script: exported.script
        )
        CustomServiceStore.save(definition)

        var defaults = exported.defaults ?? [:]
        // The identity and script belong to the definition that was just made,
        // not to whatever the document carried, so a hand-edited file cannot
        // overwrite them.
        for key in ServiceExportFilter.serviceKeys { defaults.removeValue(forKey: key) }

        CustomServiceStore.update(id: definition.id) { object in
            for (key, value) in defaults where ServiceExportFilter.shouldExportServiceKey(key) {
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

    /// Whether an instance of this kind is already configured here under this
    /// name, so the import can skip it instead of adding a duplicate.
    private static func isAlreadyPresent(type: String, name: String) -> Bool {
        let folded = name.lowercased()
        return ServiceInstanceStore.instances().contains {
            $0.type == type && $0.name.lowercased() == folded
        }
    }

    /// The instance name to use, suffixing to avoid a collision.
    private static func uniqueInstanceName(_ name: String) -> String {
        guard !ServiceInstanceStore.isNameAvailable(name) else { return name }
        var index = 2
        while !ServiceInstanceStore.isNameAvailable("\(name) \(index)") { index += 1 }
        return "\(name) \(index)"
    }

    // MARK: - Preview

    /// The icon a document says a service carries, or `nil` when it carries none.
    ///
    /// Read from the document rather than from what is stored here: a preview
    /// describes what is *in the file*, and showing this device's existing logo
    /// would be describing the wrong thing. The bundled artwork, which lives in
    /// the Preferences layer, is left to the caller to fall back to.
    public static func storedIcon(for service: ServiceExport.ExportedService) -> UIImage? {
        guard let base64 = service.defaults?[PrefKey.customIcon] as? String else { return nil }
        return ServiceIcon.image(fromBase64: base64)
    }

    /// The same, for an instance.
    public static func storedIcon(for instance: ServiceExport.ExportedInstance) -> UIImage? {
        guard let base64 = instance.settings?[PrefKey.customIcon] as? String else { return nil }
        return ServiceIcon.image(fromBase64: base64)
    }

    /// Whether this device already has the script an instance refers to by name.
    ///
    /// The import preview uses this to say so up front: an instance whose script
    /// is neither in the document nor on this device cannot be imported, and
    /// finding that out after ticking it would be a poor way to learn it.
    public static func hasService(named name: String) -> Bool {
        let folded = name.lowercased()
        return CustomServiceStore.definitions().contains { $0.name.lowercased() == folded }
    }
}
