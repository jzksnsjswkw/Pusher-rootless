import Foundation

/// One rule the user wrote to suppress notifications.
///
/// A rule is a condition plus what to do when it holds. The condition is a
/// keyword, where to look for it, and whether its presence means match or no
/// match; the outcome is one of three, and they are not degrees of the same
/// thing — see ``Action``.
///
/// Rules live in two places: a global list and a list per instance. The instance
/// list is checked first, and a rule that fires there wins — which is what makes
/// the instance an override rather than an extension. Both lists share an
/// ``Scope``: which apps the list applies to at all.
public struct FilterRule {

    /// Where in the notification the keyword is looked for.
    ///
    /// `any` means "any of the three fields", not "the three fields concatenated":
    /// a keyword spanning a field boundary would not be something a person writing
    /// a rule would expect to match, and with `doesNotContain` a concatenation
    /// makes the question harder to answer rather than easier.
    public enum Field: String, CaseIterable {
        case any
        case title
        case subtitle
        case message

        /// The name a page shows. English, because the Core layer cannot see the
        /// bundle's string table; the page localizes it.
        public var label: String {
            switch self {
            case .any: return "Whole message"
            case .title: return "Title only"
            case .subtitle: return "Subtitle only"
            case .message: return "Message only"
            }
        }
    }

    /// Whether the keyword's presence is what matches.
    public enum Relation: String, CaseIterable {
        case contains
        case doesNotContain

        public var label: String {
            switch self {
            case .contains: return "Contains"
            case .doesNotContain: return "Does not contain"
            }
        }
    }

    /// What happens when a rule matches.
    ///
    /// Three outcomes rather than a suppression switch and a notify switch,
    /// because the middle one is the reason the feature exists and no combination
    /// of two booleans expresses it as plainly: a notification the phone shows but
    /// Pusher does not forward is a different thing from one it hides.
    public enum Action: String, CaseIterable {
        /// Neither show it nor forward it.
        case suppressAll
        /// Forward it, but do not show it.
        case suppressNotification
        /// Show it, but do not forward it.
        case suppressForward

        public var label: String {
            switch self {
            case .suppressAll: return "Hide and do not forward"
            case .suppressNotification: return "Forward only"
            case .suppressForward: return "Show only"
            }
        }

        /// Whether the notification appears on the device.
        ///
        /// Written as an equality against the one case that shows it, not as a
        /// comparison against the one that hides it: two of the three cases hide
        /// it, so "not suppressed" would be the wrong shape for this question and
        /// the wrong answer for `suppressNotification`.
        public var showsNotification: Bool {
            self == .suppressForward
        }

        /// Whether Pusher forwards it — true for one case of the three.
        public var forwards: Bool {
            self == .suppressNotification
        }
    }

    /// Which apps a list of rules applies to.
    ///
    /// One scope per list, not one per rule: the page asks for it once, above the
    /// rules, because "which notifications am I talking about" is a question about
    /// the whole list. Per-rule scopes would also multiply the ways two rules can
    /// disagree, for a feature nobody has asked to combine that way.
    public struct Scope {

        /// Whether the rules apply to the selected apps or to everything else.
        ///
        /// Named for what the rules do, not for a colour on a list. "Blacklist"
        /// said the opposite of what this does: it reads as "block the apps you
        /// picked", when the rules run *on* the apps you picked — a UI that
        /// filters selected apps is the intuitive reading, and the one the page
        /// now uses.
        public enum Target: String, CaseIterable {
            /// The rules run on the selected apps, and nothing else.
            case selected
            /// The rules run on every app except the selected ones.
            case unselected

            public var label: String {
                switch self {
                case .selected: return "Filter selected apps"
                case .unselected: return "Do not filter selected apps"
                }
            }
        }

        public var target: Target = .selected
        public var apps: [String] = []

        /// Whether the rules apply to `appID` at all.
        ///
        /// The two cases are complements, including on an empty list: "filter the
        /// selected apps" with none selected filters nothing, and "do not filter
        /// the selected apps" with none selected filters everything — which is what
        /// each sentence says. A rule whose list is still empty is harmless either
        /// way, because a rule with no keyword never matches.
        public func covers(appID: String) -> Bool {
            let listed = apps.contains(appID)
            switch target {
            case .selected: return listed
            case .unselected: return !listed
            }
        }
    }

    /// Whether the rule is in force.
    ///
    /// Separate from deleting it: a rule the user wants to keep but not apply —
    /// a keyword they will need again next week — should not have to be retyped.
    public var isEnabled = true

    public var field: Field = .any
    public var relation: Relation = .contains
    public var keyword: String = ""
    public var action: Action = .suppressAll

    public init(field: Field = .any, relation: Relation = .contains,
                keyword: String = "", action: Action = .suppressAll,
                isEnabled: Bool = true) {
        self.isEnabled = isEnabled
        self.field = field
        self.relation = relation
        self.keyword = keyword
        self.action = action
    }

    /// Whether this rule's condition holds for `context`.
    ///
    /// An empty keyword matches everything: it is how a rule says "every
    /// notification from these apps", which is the common case — someone who wants
    /// one app's notifications to stop forwarding has no keyword to give.
    public func matches(_ context: BulletinContext) -> Bool {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return true }
        return contains(keyword, in: context) == (relation == .contains)
    }

    /// Whether `keyword` appears in the field this rule watches.
    private func contains(_ keyword: String, in context: BulletinContext) -> Bool {
        switch field {
        case .any:
            return [context.title, context.subtitle, context.message]
                .contains { value in
                    value?.range(of: keyword, options: .caseInsensitive) != nil
                }
        case .title:
            return context.title?.range(of: keyword, options: .caseInsensitive) != nil
        case .subtitle:
            return context.subtitle?.range(of: keyword, options: .caseInsensitive) != nil
        case .message:
            return context.message?.range(of: keyword, options: .caseInsensitive) != nil
        }
    }

    // MARK: - Storage

    /// The shape a rule is stored in: a dictionary of strings, so a stored rule is
    /// readable and survives a field being added with a working default.
    public var stored: [String: Any] {
        [
            FilterRuleKey.enabled: isEnabled,
            FilterRuleKey.field: field.rawValue,
            FilterRuleKey.relation: relation.rawValue,
            FilterRuleKey.keyword: keyword,
            FilterRuleKey.action: action.rawValue,
        ]
    }

    public init(stored object: [String: Any]) {
        let prefs = Prefs(object)
        isEnabled = prefs.bool(FilterRuleKey.enabled, default: true)
        field = Field(rawValue: prefs.string(FilterRuleKey.field) ?? "") ?? .any
        relation = Relation(rawValue: prefs.string(FilterRuleKey.relation) ?? "") ?? .contains
        keyword = prefs.string(FilterRuleKey.keyword) ?? ""
        action = Action(rawValue: prefs.string(FilterRuleKey.action) ?? "") ?? .suppressAll
    }
}

enum FilterRuleKey {
    static let enabled = "enabled"
    static let field = "field"
    static let relation = "relation"
    static let keyword = "keyword"
    static let action = "action"
}

/// A list of rules and the apps it applies to.
/// One group: a scope and the rules that apply within it.
///
/// A user with two kinds of notification to deal with — ads from shopping apps, and
/// everything from a work chat — has two groups. Each carries its own app list
/// because the list *is* half of what a group says: "these apps, these keywords"
/// is one statement, and splitting it across a page made the second half read as
/// if it applied to everything.
public struct FilterRuleGroup {
    public var scope = FilterRule.Scope()
    public var rules: [FilterRule] = []

    public init() {}
    public init(scope: FilterRule.Scope, rules: [FilterRule]) {
        self.scope = scope
        self.rules = rules
    }

    /// What this group decides for `context`, or `nil` when it has no opinion.
    ///
    /// The first matching rule wins, so the order of the rules is the order of
    /// precedence — which is why the page lets the user drag them. A group whose
    /// scope does not cover the app has no opinion regardless of its rules.
    public func outcome(for context: BulletinContext) -> FilterRule.Action? {
        guard scope.covers(appID: context.appID) else { return nil }
        return rules.first { $0.isEnabled && $0.matches(context) }?.action
    }

    /// A group with nothing in it is still shown and stored: it is what the user
    /// just added, and it is where the rules are about to go.
    public var isEmpty: Bool { rules.isEmpty }

    // MARK: - Storage

    /// Stored as one dictionary, so a scope and its rules cannot be separated by a
    /// half-written save.
    public var stored: [String: Any] {
        [
            FilterRuleSetKey.target: scope.target.rawValue,
            FilterRuleSetKey.apps: scope.apps,
            FilterRuleSetKey.rules: rules.map(\.stored),
        ]
    }

    public init(stored object: [String: Any]) {
        let prefs = Prefs(object)
        scope.target = FilterRule.Scope.Target(rawValue: prefs.string(FilterRuleSetKey.target) ?? "")
            ?? .selected
        scope.apps = prefs.stringArray(FilterRuleSetKey.apps)
        rules = prefs.dictionaries(FilterRuleSetKey.rules).map { FilterRule(stored: $0.raw) }
    }
}

/// The groups a page edits and the engine reads.
///
/// Groups are asked in order and the first one with an opinion wins, so a group
/// higher in the list takes precedence — the same rule the rules inside a group
/// follow, one level up.
public struct FilterRuleSet {
    public var groups: [FilterRuleGroup] = []

    public init() {}
    public init(groups: [FilterRuleGroup]) { self.groups = groups }

    /// A single-group set, for the pages that were written before groups existed.
    public init(scope: FilterRule.Scope, rules: [FilterRule]) {
        groups = [FilterRuleGroup(scope: scope, rules: rules)]
    }

    /// What this set decides for `context`, or `nil` when it has no opinion.
    public func outcome(for context: BulletinContext) -> FilterRule.Action? {
        for group in groups {
            if let action = group.outcome(for: context) { return action }
        }
        return nil
    }

    /// Whether there is nothing to store.
    ///
    /// A group with no rules in it is *not* nothing: the user just added it, and
    /// dropping it would make `+` appear to do nothing. Only a set with no groups
    /// at all is empty.
    public var isEmpty: Bool { groups.isEmpty }

    /// How many rules there are, across every group.
    public var ruleCount: Int { groups.reduce(0) { $0 + $1.rules.count } }

    // MARK: - Storage

    /// Stored as an array of groups. A set written before groups existed is a
    /// single dictionary, which is read as one group — see ``init(stored:)``.
    public var stored: [String: Any] {
        [FilterRuleSetKey.groups: groups.map(\.stored)]
    }

    public init(stored object: [String: Any]) {
        let prefs = Prefs(object)
        let storedGroups = prefs.dictionaries(FilterRuleSetKey.groups)
        if storedGroups.isEmpty, object[FilterRuleSetKey.rules] != nil {
            // The single-group shape: a scope and a rule list at the top level.
            groups = [FilterRuleGroup(stored: object)]
        } else {
            groups = storedGroups.map { FilterRuleGroup(stored: $0.raw) }
        }
    }
}

enum FilterRuleSetKey {
    static let groups = "groups"
    static let target = "target"
    static let apps = "apps"
    static let rules = "rules"
}
