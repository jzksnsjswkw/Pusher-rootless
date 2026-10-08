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

    // MARK: Script services

    /// How long a user script may run before it is abandoned. Long enough for a
    /// couple of network round trips, short enough that a runaway script is not
    /// left holding a login item.
    public static let defaultScriptTimeout: TimeInterval = 2

    /// How long one `fetch` from a script may take.
    public static let scriptFetchTimeout: TimeInterval = 10

    /// The largest response body a script's `fetch` will accept, in bytes. A
    /// larger body is truncated and noted on the console rather than refused.
    public static let defaultMaxResponseBytes = 1_048_576
    /// The same limit, in the MB the settings page shows.
    public static let defaultMaxResponseMB = 1

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
/// Values are deliberately stored as strings rather than an enum: prefs are read
/// from a hand-editable plist, so every lookup stays a plain string key.
public enum PrefKey {
    // Top-level containers.
    //
    // `Services` is the ordered array of service *instances* and is the single
    // source of truth for what the pipeline sends to. `Global` holds the
    // settings that are not per-instance.
    public static let services = "Services"
    /// The user's service *definitions*: the scripts that make new kinds of
    /// service, which the `Services` list then references by id.
    public static let customServices = "CustomServices"
    public static let global = "Global"

    // Identity of one entry in `Services`. `id` is stable and opaque while
    // `type` names the descriptor that builds the request; they are separate so
    // an instance can be renamed without losing its log or its storage.
    public static let instanceID = "id"
    public static let instanceType = "type"
    public static let instanceName = "name"

    // Global (non-service) settings.
    public static let enabled = "Enabled"
    public static let whenToPush = "WhenToPush"
    public static let whatNetwork = "WhatNetwork"


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

    // MARK: Script services

    /// The user's JavaScript source.
    public static let script = "script"
    /// A definition's own explanatory text, shown on its page.
    public static let serviceDescription = "description"
    /// The script's `localStorage`, persisted across runs.
    public static let scriptStorage = "scriptStorage"
    /// Run every script in one shared context instead of a fresh one.
    public static let scriptShareContext = "scriptShareContext"
    /// Run every script on one shared thread instead of a fresh one.
    public static let scriptShareThread = "scriptShareThread"
    /// Seconds a run may take.
    public static let scriptTimeout = "scriptTimeout"
    /// Largest response body `fetch` accepts, in bytes.
    public static let scriptMaxResponseBytes = "scriptMaxResponseBytes"
    public static let curateData = "curateData"
    public static let imageMaxWidth = "imageMaxWidth"
    public static let imageMaxHeight = "imageMaxHeight"
    public static let imageShrinkFactor = "imageShrinkFactor"
    public static let sounds = "sounds"
    public static let devices = "devices"
    public static let appList = "appList"
    public static let appListIsBlacklist = "appListIsBlacklist"
    public static let customApps = "customApps"
    /// The `SNS-<condition>` prefix for one instance's condition toggles.
    public static let snsPrefix = "SNS-"

    // SNS filter mode: how an instance's conditions combine.
    /// Whether every selected condition must hold (AND) rather than any (OR).
    public static let snsIsAnd = "snsIsAnd"
    /// When combining with OR, whether "Allow Notifications" is still required.
    public static let snsRequireANWithOR = "snsRequireANWithOR"
    /// The resolved SNS condition keys for one service (normalized at load
    /// time, not a raw plist key).
    public static let sns = "sns"

    // Custom-service-only fields.
    public static let authenticationMethod = "authenticationMethod"
    public static let paramName = "paramName"
    public static let method = "method"
    public static let bodyType = "bodyType"

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
