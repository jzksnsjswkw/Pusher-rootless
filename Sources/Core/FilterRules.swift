import Foundation

/// Where the two rule lists live, and what the engine asks them.
///
/// The global list is stored beside the other top-level settings; an instance's is
/// stored in its own config, next to the settings it covers. Both are
/// ``FilterRuleSet``, so a page edits either with the same code and the engine
/// reads either with the same call.
public enum FilterRules {

    // MARK: - Global

    public static func global() -> FilterRuleSet {
        guard let object = PrefsStore.prefs().dict(PrefKey.globalRules) else {
            return FilterRuleSet()
        }
        return FilterRuleSet(stored: object.raw)
    }

    public static func setGlobal(_ set: FilterRuleSet) {
        // `PrefsStore.setValue` notifies the engine by Darwin notification, which
        // is what makes a new rule apply to the next bulletin rather than after a
        // respring — the hook reads the snapshot it holds.
        PrefsStore.setValue(set.isEmpty ? nil : set.stored, forKey: PrefKey.globalRules)
        NotificationCenter.default.post(name: .filterRulesChanged, object: nil)
    }

    // MARK: - Per instance

    public static func instance(_ id: String) -> FilterRuleSet {
        guard !id.isEmpty else { return FilterRuleSet() }
        let config = PrefsStore.instance(id)
        guard let object = config.dict(PrefKey.instanceRules) else { return FilterRuleSet() }
        return FilterRuleSet(stored: object.raw)
    }

    public static func setInstance(_ id: String, _ set: FilterRuleSet) {
        guard !id.isEmpty else { return }
        ServiceInstanceStore.update(id: id) {
            if set.isEmpty {
                $0.removeValue(forKey: PrefKey.instanceRules)
            } else {
                $0[PrefKey.instanceRules] = set.stored
            }
        }
        NotificationCenter.default.post(name: .filterRulesChanged, object: nil)
    }

    /// Whether any rule could possibly match, cheap enough to ask before building
    /// a context.
    ///
    /// "Has a rule" rather than "has a list": a group the user added but has not
    /// filled in is stored, and a set of nothing but empty groups cannot suppress
    /// anything — asking the question that way keeps a half-built page from
    /// costing every notification in the system a context build.
    public static var hasAnyRules: Bool {
        if holdsAMatchableRule(PrefsStore.prefs().dict(PrefKey.globalRules)?.raw) {
            return true
        }
        return ServiceInstanceStore.instances().contains {
            holdsAMatchableRule($0.config.dict(PrefKey.instanceRules)?.raw)
        }
    }

    /// Whether a stored set contains an enabled rule.
    private static func holdsAMatchableRule(_ stored: [String: Any]?) -> Bool {
        guard let stored else { return false }
        return FilterRuleSet(stored: stored).groups.contains { group in
            group.isEnabled && group.rules.contains(where: \.isEnabled)
        }
    }

    // MARK: - The question the engine asks

    /// Whether the notification should be kept off the screen entirely.
    ///
    /// Asked from the `BBServer` hook, before `%orig`: hiding means not calling it,
    /// so this answers synchronously and touches nothing slow. Only the rule lists
    /// are consulted — the instance pipeline's hooks may fetch, and a fetch cannot
    /// decide whether a notification is drawn.
    ///
    /// Any list asking for it is enough. Showing or hiding is an effect on the
    /// device, not on one destination: a notification is drawn once and either
    /// every destination sees it or none does. Forwarding is the other way round —
    /// per destination, decided in the pipeline — which is why the two halves of a
    /// rule are asked in two different places and neither is surprising.
    public static func suppressesNotification(_ context: BulletinContext) -> Bool {
        if let action = global().outcome(for: context), !action.showsNotification {
            return true
        }
        for candidate in ServiceInstanceStore.instances() where candidate.isEnabled {
            if let action = instance(candidate.id).outcome(for: context),
               !action.showsNotification {
                return true
            }
        }
        return false
    }
}

public extension Notification.Name {
    /// Posted after the rule lists are edited, so an open page can refresh.
    static let filterRulesChanged = Notification.Name("PusherFilterRulesChanged")
}
