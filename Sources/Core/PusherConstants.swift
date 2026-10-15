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

    /// Where an instance keeps its own settings.
    ///
    /// Everything an instance *is* — `id`, `type`, `name`, `enabled` — is a key
    /// of the instance object; everything it *carries* lives under this one.
    /// They were flat, and a service that wanted a setting called `id` wrote over
    /// the instance's own identity: Bark has a push parameter of exactly that
    /// name, so its field read the instance's UUID and typing into it would have
    /// renamed the instance, orphaning its log and its stored values.
    ///
    /// A service cannot know the framework's key names, and a service's own
    /// vocabulary should not have to. The separation is not a convention it has to
    /// observe; it is where the storage layer puts things.
    public static let instanceConfig = "config"

    /// The prefix on every key the framework owns inside a resolved config.
    ///
    /// A service reads its settings from `ServiceConfig.raw`, and a service is
    /// free to name them whatever the API it calls expects — Bark has a parameter
    /// called `id` and another called `key`. The framework's own keys used to sit
    /// in the same dictionary under their bare names, so a service that happened
    /// to want `appList` or `whenToPush` read the framework's value instead of its
    /// own, and a service that wanted anything the framework also wanted could not
    /// say so at all.
    ///
    /// Prefixed, the two vocabularies cannot collide: the framework reads and
    /// writes through the prefix, a service reads the bare name, and neither has
    /// to know what the other is called. The payload options a service *is*
    /// supposed to read — `includeIcon`, `imageMaxWidth`, `dateFormat` — keep
    /// their bare names, because those are the framework handing the service its
    /// parameters rather than the framework talking to itself.
    public static let frameworkPrefix = "fw."

    /// The keys that belong to the instance object itself, never to its config.
    ///
    /// Anything else an instance object holds at this level is a leftover from
    /// the flat layout this replaced, and is discarded on the next write. The
    /// split arrived before the first release that used it, so there is no
    /// configuration in the wild to carry across.
    public static let instanceIdentityKeys: Set<String> = [
        instanceID, instanceType, instanceName, serviceEnabled,
    ]

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
    /// A service's own icon, as base64 PNG.
    ///
    /// Stored pre-rendered at the chosen size, so the payload can use it
    /// verbatim: rendering a symbol per notification would cost a draw for a
    /// picture that never changes.
    public static let customIcon = "customIcon"
    /// The gallery symbol the icon was drawn from, when it came from the
    /// gallery. Kept so the picker can show what is selected.
    public static let customIconSymbol = "customIconSymbol"
    /// The tint the symbol was drawn in, as an index into the gallery's tints.
    public static let customIconTint = "customIconTint"
    /// How the icon is stored, so the picker can reopen the right section.
    public static let customIconSource = "customIconSource"
    /// The stored icon's side length in pixels.
    public static let customIconSize = "customIconSize"

    /// Largest response body `fetch` accepts, in bytes.
    public static let scriptMaxResponseBytes = "scriptMaxResponseBytes"

    // MARK: Instance hooks

    // Two optional hooks per instance, each with its own switch. The switch is
    // what keeps an abandoned experiment free: an empty or disabled hook is
    // never executed, so it cannot cost anything on every notification.
    /// Whether the "received" hook runs.
    public static let hookReceivedEnabled = "hookReceivedEnabled"
    /// Its source.
    public static let hookReceivedScript = "hookReceivedScript"
    /// Whether the "filtered" hook runs.
    public static let hookFilteredEnabled = "hookFilteredEnabled"
    /// Its source.
    public static let hookFilteredScript = "hookFilteredScript"
    /// Each hook's `localStorage`, kept per instance *and per hook*.
    public static let hookStorage = "hookStorage"

    // MARK: Service config fields

    /// A service's declared settings — its own vocabulary, on the definition.
    public static let configFields = "configFields"
    /// An instance's values for those settings.
    public static let configValues = "configValues"
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
    //
    // Two spellings each, because the app has used both and the older one is
    // still what some builds wrote: the Objective-C original wrote the long name
    // and read the short one as a fallback (see the reader in `PushConfig`), so
    // a configuration from either era must still be understood. The long name is
    // what gets written from now on, since it is what the original's *global*
    // keys were called and the two live side by side in one preference domain.
    /// Whether every selected condition must hold (AND) rather than any (OR).
    public static let snsIsAnd = "SufficientNotificationSettingsIsAnd"
    /// When combining with OR, whether "Allow Notifications" is still required.
    public static let snsRequireANWithOR = "SNSORRequireAllowNotifications"

    /// The older, shorter spellings, read as fallbacks.
    ///
    /// Only the two switches ever had two names; the per-condition toggles have
    /// always been `SNS-<condition>`. `short(_:)` maps between them so a reader
    /// never has to hold both spellings in mind.
    public enum SNSAlias {
        public static let isAnd = "snsIsAnd"
        public static let requireANWithOR = "snsRequireANWithOR"

        /// The older name for a key, or `nil` when it never had one.
        public static func short(_ key: String) -> String? {
            switch key {
            case PrefKey.snsIsAnd: return isAnd
            case PrefKey.snsRequireANWithOR: return requireANWithOR
            default: return nil
            }
        }
    }
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
