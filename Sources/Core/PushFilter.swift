import Foundation

/// The pre-flight filters.
///
/// Every input is a plain value type or a config snapshot, so these are pure
/// decisions. The ObjC version reached into `BBServer` / `BBSectionInfo` /
/// `SBLockScreenManager` from here; all of that now happens
/// once, in ``BulletinAdapter``.
///
/// Each method returns the reason to block, or `nil` to let the bulletin
/// through. The reason is logged verbatim, so it is written to read well in the
/// log viewer rather than as an error code.
public enum PushFilter {

    /// The global pre-flight for one bulletin: Pusher enabled, the test-result
    /// banner, the global app list, whether SpringBoard could supply this app's
    /// settings at all, and whether every enabled service has a config.
    public static func globalReason(context: BulletinContext, config: ConfigSnapshot) -> String? {
        PusherLog.debug("-------Bulletin------- \(context.appID)")

        guard config.enabled else {
            return "Pusher Disabled"
        }

        // A forwarded push produces a notification of its own; never forward
        // the banner reporting the result of a test push, or it would loop.
        if context.appID == testNotificationSectionID,
           context.title == Pusher.name,
           let message = context.message, message.hasPrefix(testPushResultPrefix) {
            return "Not forwarding test notification result banner"
        }

        // The adapter reports why SpringBoard had no settings for this app.
        if let reason = context.notificationSettingsUnavailableReason {
            return reason
        }

        // Every instance that is about to be fanned out to must have a config.
        // (An empty enabled list is not an error here: the engine logs it and
        // stops without treating the bulletin as filtered.)
        for instance in config.enabledInstances where config.config(forID: instance.id) == nil {
            return "Service prefs are nil, they shouldn't be"
        }

        return nil
    }

    /// The per-service app list. A blacklist blocks listed apps; a whitelist
    /// blocks everything else.
    ///
    /// `nil` — the segment's "Default" — applies nothing here: the global list
    /// has already had its say before the per-instance loop, and re-checking it
    /// per instance would only repeat the same verdict.
    public static func appListReason(config: ServiceConfig, appID: String) -> String? {
        guard let isBlacklist = config.appListIsBlacklist else { return nil }
        return appListReason(
            appList: config.appList,
            isBlacklist: isBlacklist,
            appID: appID
        )
    }

    /// The same check against the global app list, whose storage is the
    /// `Global` object rather than a service.
    public static func globalAppListReason(config: ConfigSnapshot, appID: String) -> String? {
        appListReason(
            appList: config.globalAppList,
            isBlacklist: config.globalAppListIsBlacklist,
            appID: appID
        )
    }

    /// The list that decides for this instance: its own, or the global one.
    ///
    /// An instance that has chosen blacklist or whitelist owns the decision —
    /// its list, even empty, replaces the global list rather than adding to it.
    /// Otherwise a global blacklist could never be lifted for one destination,
    /// and an instance whose list is empty would be filtered by a list it never
    /// asked to follow.
    ///
    /// "Default" — no mode stored — is the case that follows the global list.
    public static func effectiveAppListReason(
        config: ServiceConfig, global: ConfigSnapshot, appID: String
    ) -> String? {
        guard let isBlacklist = config.appListIsBlacklist else {
            return globalAppListReason(config: global, appID: appID)
        }
        return appListReason(
            appList: config.appList, isBlacklist: isBlacklist, appID: appID
        )
    }

    private static func appListReason(appList: [String], isBlacklist: Bool, appID: String) -> String? {
        let contains = appList.contains(appID)
        // Both a blacklist hit and a whitelist miss are "the app is listed when
        // it should not be (or is not when it should be)".
        guard isBlacklist == contains else { return nil }
        return "Blocked by app list (\(isBlacklist ? "blacklist" : "whitelist"))"
    }

    /// The per-app notification-settings filter.
    public static func snsReason(
        sns: [String],
        settings: NotificationSettings,
        isAnd: Bool,
        requireANWithOR: Bool
    ) -> String? {
        if !isAnd, requireANWithOR, !settings.allowsNotifications {
            return "'OR' and 'Require Allow Notifications with OR' both on, but Allow "
                + "Notifications is disabled in this app's settings."
        }

        // No conditions configured: nothing to check, let it through. (An empty
        // list in OR mode would otherwise block everything, because the loop
        // below never finds anything "sufficient".)
        guard !sns.isEmpty else { return nil }

        var foundSufficient = false
        for key in sns {
            guard let condition = SNSCondition(rawValue: key) else {
                // Unknown condition key: treat it as unsatisfied so a config
                // typo cannot silently bypass the filter. Defensive only — the
                // loader only ever produces known keys.
                PusherLog.debug("Unknown SNS condition key: \(key)")
                if isAnd { return "'AND' but \(key) incorrect" }
                continue
            }

            let sufficient = settings.isSatisfied(condition)
            if isAnd, !sufficient {
                return "'AND' but \(key) incorrect"
            }
            if !isAnd, sufficient {
                PusherLog.debug("OR and sufficient: \(key)")
                foundSufficient = true
                break
            }
        }

        // `foundSufficient` has to be tracked explicitly: returning here on the
        // first unsatisfied condition in OR mode would block every notification
        // even when a later condition matched.
        if !isAnd, !foundSufficient {
            PusherLog.debug("OR and insufficient")
            return "'OR' and none were correct"
        }
        return nil
    }

    /// The device-condition filter (lock state and network).
    public static func deviceReason(
        whenToPush: WhenToPush,
        whatNetwork: WhatNetwork,
        deviceState: DeviceState
    ) -> String? {
        let onWiFi = deviceState.isOnWiFi
        if (whatNetwork == .wifiOnly && !onWiFi) || (whatNetwork == .cellularOnly && onWiFi) {
            return "What Network set to \(whatNetwork.label) but \(onWiFi ? "" : "not ")on WiFi"
        }

        let locked = deviceState.isLocked
        if (whenToPush == .locked && !locked) || (whenToPush == .unlocked && locked) {
            return "When to Push set to \(whenToPush.label) but device \(locked ? "" : "un")locked"
        }
        return nil
    }
}

// MARK: - Test push constants

/// Section ID of the synthetic test bulletin: the Settings app, so an arriving
/// test notification looks like any other.
public let testNotificationSectionID = "com.apple.Preferences"
/// Prefix of the banner reporting a test push result.
public let testPushResultPrefix = "Test Notification Result: "
