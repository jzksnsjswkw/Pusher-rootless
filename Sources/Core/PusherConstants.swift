import Foundation
import notify

/// Shared constants for the whole Pusher pipeline.
///
/// Kept free of UIKit / SpringBoard / Preferences imports so the Core layer
/// stays self-contained and can be compiled into the tweak, the Preferences
/// bundle and the Flipswitch bundle alike.
public enum Pusher {
    /// Human-readable name used in alerts and log prefixes.
    public static let name = "Pusher"

    // MARK: - Preference domains

    public static let appID = "com.noahsaso.pusher"
    public static let logDomain = "com.noahsaso.pusher~log"

    /// Darwin notifications posted after a preference write.
    public static let prefsNotification = "com.noahsaso.pusher/prefs"
    public static let logPrefsNotification = "com.noahsaso.pusher~log/prefs"

    // MARK: - Push request tuning

    /// How many times Pusher will try to send the web request.
    public static let tries = 5
    /// Recent bulletin contents scanned by loop prevention.
    public static let loopPreventionWindow = 25
    /// Repeats of the same content needed to block a notification.
    public static let loopPreventionThreshold = 10
    /// Delay between transport-level retries, in seconds.
    public static let delayBetweenRetries: TimeInterval = 3

    // MARK: - Logging

    public static let logMaxStringLength = 50
    /// Properties whose values are large Base64 image data, replaced with
    /// ``logImageDataReplacement`` in sanitized log copies.
    public static let logImageDataProperties = ["icon", "image"]
    public static let logImageDataReplacement = "[Base64 Image String]"

    // MARK: - Image defaults

    public static let defaultMaxWidth: CGFloat = 1000
    public static let defaultMaxHeight: CGFloat = 1000
    public static let defaultShrinkFactor: CGFloat = 2.5

    // MARK: - Test push

    public static let messagingCenterName = "com.noahsaso.pusher/testpush"
    public static let testPushMessageName = "sendTest"

    // MARK: - Installed bundle

    /// The installed Preferences bundle, which is where this tweak's resources
    /// live.
    ///
    /// The path goes through `jbroot()` so it resolves on a rootless or
    /// roothide install (the tweak runs from the jailbreak root, not the system
    /// root). In a jailbroken-but-rootful build `jbroot` is the identity
    /// function.
    public static var bundlePath: String? {
        // `jbroot` is overloaded for `NSString` in the roothide header, so Swift
        // resolves the String form directly and the pointer handling stays on
        // the C side.
        let path: String = jbroot("/Library/PreferenceBundles/Pusher.bundle")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// The Preferences bundle, or `nil` when it has not been installed.
    public static var bundle: Bundle? {
        bundlePath.flatMap(Bundle.init(path:))
    }
}

/// Preference-key names, mirroring the on-disk plist layout.
///
/// Values are deliberately stored as strings rather than an enum: prefs are
/// read from a hand-editable plist, so every lookup stays a plain string key.
public enum PrefKey {
    // Top-level containers.
    public static let builtInServices = "BuiltInServices"
    public static let customServices = "CustomServices"
    public static let global = "Global"

    // Legacy flat-key prefixes, used by the migration layer only.
    public static let globalBlacklistPrefix = "GlobalBL-"
    public static let snsPrefix = "SNS-"
    public static let legacyCustomAppsPrefix = "CustomService_"
    public static let legacyCustomAppsSuffix = "_CustomApps"
    public static let legacyCustomBlacklistPrefix = "CustomServiceBL_"

    // Global (non-service) settings.
    public static let enabled = "Enabled"
    public static let whenToPush = "WhenToPush"
    public static let whatNetwork = "WhatNetwork"
    public static let legacyGlobalAppListIsBlacklist = "GlobalAppListIsBlacklist"

    // SNS filter mode. Two spellings exist for each: the original verbose key
    // (still what the UI plists and older builds write) and the short one the
    // normalized service prefs use. Reads check both; writes use the short one.
    public static let snsIsAnd = "snsIsAnd"
    public static let snsRequireANWithOR = "snsRequireANWithOR"
    public static let snsIsAndAlt = "SufficientNotificationSettingsIsAnd"
    public static let snsRequireANWithORAlt = "SNSORRequireAllowNotifications"

    // Generic per-service field names, shared by every built-in service.
    public static let serviceEnabled = "enabled"
    public static let token = "token"
    public static let user = "user"
    public static let key = "key"
    public static let url = "url"
    public static let eventName = "eventName"
    public static let dbName = "dbName"
    public static let serverURL = "serverURL"
    public static let corpid = "corpid"
    public static let corpsecret = "corpsecret"
    public static let agentID = "agentID"
    public static let touser = "touser"
    public static let dateFormat = "dateFormat"
    public static let includeIcon = "includeIcon"
    public static let includeImage = "includeImage"
    public static let curateData = "curateData"
    public static let imageMaxWidth = "imageMaxWidth"
    public static let imageMaxHeight = "imageMaxHeight"
    public static let imageShrinkFactor = "imageShrinkFactor"
    public static let sounds = "sounds"
    public static let devices = "devices"
    public static let appList = "appList"
    public static let appListIsBlacklist = "appListIsBlacklist"
    public static let customApps = "customApps"
    public static let isCustomService = "isCustomService"
    /// The resolved SNS condition keys for one service (normalized at load
    /// time, not a raw plist key).
    public static let sns = "sns"

    // Custom-service-only fields.
    public static let authenticationMethod = "authenticationMethod"
    public static let paramName = "paramName"
    public static let method = "method"
    public static let bodyType = "bodyType"

    // Legacy per-service key basenames, migrated into the nested object.
    public static let legacyEnabled = "Enabled"
    public static let legacyToken = "Token"
    public static let legacyUser = "User"
    public static let legacyKey = "Key"
    public static let legacyEventName = "EventName"
    public static let legacyDateFormat = "DateFormat"
    public static let legacyServerURL = "ServerURL"
    public static let legacyDBName = "DBName"
    public static let legacyAppListIsBlacklist = "AppListIsBlacklist"
    public static let legacyWhenToPush = "WhenToPush"
    public static let legacyWhatNetwork = "WhatNetwork"
    public static let legacySNSIsAnd = "SufficientNotificationSettingsIsAnd"
    public static let legacySNSRequireANWithOR = "SNSORRequireAllowNotifications"
    public static let legacyDevices = "Devices"
    public static let legacySounds = "Sounds"
    public static let legacyCustomApps = "CustomApps"
    public static let legacyIncludeIcon = "IncludeIcon"
    public static let legacyCurateData = "CurateData"
    public static let legacyIncludeImage = "IncludeImage"
    public static let legacyImageMaxWidth = "ImageMaxWidth"
    public static let legacyImageMaxHeight = "ImageMaxHeight"
    public static let legacyImageShrinkFactor = "ImageShrinkFactor"
    public static let legacyCorpid = "Corpid"
    public static let legacyCorpsecret = "Corpsecret"
    public static let legacyAgentID = "AgentID"
    public static let legacyTouser = "Touser"
    public static let legacyBlacklistPrefix = "BL-"

    /// Log key suffix for one service (`<service>Log`).
    public static func logKey(forService service: String) -> String { "\(service)Log" }

    /// Whether logging is enabled for one service.
    public static func logEnabledKey(forService service: String) -> String { "\(service)LogEnabled" }
}

/// The `SNS-<condition>` toggles an app's notification settings are checked
/// against.
public enum SNSCondition: String, CaseIterable {
    case allowNotifications = "AllowNotifications"
    case lockScreen = "LockScreen"
    case notificationCenter = "NotificationCenter"
    case banners = "Banners"
    case badges = "Badges"
    case sounds = "Sounds"
    case showsPreviews = "ShowsPreviews"

    /// Default state when a condition key is absent from prefs.
    /// Only "Allow Notifications" is required by default.
    public var defaultValue: Bool { self == .allowNotifications }
}

/// "When to push" choices (the device's lock state).
public enum WhenToPush: Int, CaseIterable {
    case locked = 0
    case either = 1
    case unlocked = 2

    public var label: String {
        switch self {
        case .locked: return "Locked"
        case .either: return "Either"
        case .unlocked: return "Unlocked"
        }
    }
}

/// "What network" choices.
public enum WhatNetwork: Int, CaseIterable {
    case any = 0
    case wifiOnly = 1
    case cellularOnly = 2

    public var label: String {
        switch self {
        case .any: return "Any Network"
        case .wifiOnly: return "WiFi Only"
        case .cellularOnly: return "Cellular Only"
        }
    }
}

/// Segment cells use `-1` to mean "not configured".
public let segmentCellDefault = -1

/// Header name used by the form-encoded body type.
public let formContentType = "application/x-www-form-urlencoded; charset=utf-8"
