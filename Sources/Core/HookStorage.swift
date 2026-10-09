import Foundation

/// The `localStorage` of an instance's two hooks.
///
/// Kept per instance **and per hook**, so the "received" hook and the "filtered"
/// hook of the same instance do not share state. That is the useful default: the
/// first hook usually accumulates what it saw (a message it classified, a count)
/// and the second decides with it, and either can be edited without disturbing
/// the other's variables.
///
/// Stored under one key of the instance's config, shaped
/// `{ "<phase>": { key: value } }`, so reading and writing stay a single
/// preference round trip rather than one per hook.
public enum HookStorage {
    /// The values one hook left behind last time.
    public static func values(
        forService service: String,
        phase: BulletinHookRunner.Phase
    ) -> [String: String] {
        guard let stored = PrefsStore.instance(service).dict(PrefKey.hookStorage),
              let perPhase = stored.dict(phase.rawValue)
        else { return [:] }
        return perPhase.raw.compactMapValues { $0 as? String }
    }

    /// Writes one hook's values back onto its instance.
    ///
    /// Only written when they changed: this runs on every notification, and a
    /// hook that keeps no state must not rewrite the preference each time.
    public static func setValues(
        _ values: [String: String],
        forService service: String,
        phase: BulletinHookRunner.Phase
    ) {
        guard !service.isEmpty else { return }
        guard values != self.values(forService: service, phase: phase) else { return }
        PrefsStore.updateInstance(service) { object in
            var container = (object[PrefKey.hookStorage] as? [String: Any]) ?? [:]
            container[phase.rawValue] = values
            object[PrefKey.hookStorage] = container
        }
    }
}
