// Shared constants for the push pipeline (Core/, Core/Services/) and, via
// global.h, the Preferences bundle / Flipswitch switch. Kept free of UIKit /
// SpringBoard / Preferences dependencies so the Core layer stays
// self-contained and never drags in UI-layer headers.

#import <Foundation/Foundation.h>

#define kName @"Pusher"

#define PUSHER_PREFS_NOTIFICATION "com.noahsaso.pusher/prefs"
#define PUSHER_APP_ID CFSTR("com.noahsaso.pusher")
#define PUSHER_LOG_PREFS_NOTIFICATION "com.noahsaso.pusher~log/prefs"
#define PUSHER_LOG_ID CFSTR("com.noahsaso.pusher~log")

#define PUSHER_TRIES 5 // how many times pusher will try to send the web request
#define PUSHER_LOOP_PREVENTION_WINDOW 25   // recent titles to scan
#define PUSHER_LOOP_PREVENTION_THRESHOLD 10 // repeats of the same title to block
#define PUSHER_LOG_MAX_STRING_LENGTH 50
#define PUSHER_LOG_IMAGE_DATA_PROPERTIES                                       \
  @[                                                                           \
    @"icon", @"image"                                                          \
  ] // properties to replace with PUSHER_LOG_IMAGE_DATA_REPLACEMENT in the log
#define PUSHER_LOG_IMAGE_DATA_REPLACEMENT @"[Base64 Image String]"
#define PUSHER_DEFAULT_MAX_WIDTH 1000.0
#define PUSHER_DEFAULT_MAX_HEIGHT 1000.0
#define PUSHER_DEFAULT_SHRINK_FACTOR 2.5
#define PUSHER_DELAY_BETWEEN_RETRIES 3

#define PUSHER_MESSAGING_CENTER_NAME @"com.noahsaso.pusher/testpush"
#define PUSHER_TEST_PUSH_MESSAGE_NAME @"sendTest"

#define NSPPreferenceGlobalBLPrefix @"GlobalBL-"
#define NSPPreferenceSNSPrefix @"SNS-"

#define PUSHER_SEGMENT_CELL_DEFAULT -1

#define PUSHER_WHAT_NETWORK_ANY 0
#define PUSHER_WHAT_NETWORK_WIFI_ONLY 1
#define PUSHER_WHAT_NETWORK_OFF_WIFI_ONLY 2

#define PUSHER_WHEN_TO_PUSH_LOCKED 0
#define PUSHER_WHEN_TO_PUSH_EITHER 1
#define PUSHER_WHEN_TO_PUSH_UNLOCKED 2

#define PUSHER_TEST_NOTIFICATION_TITLE @"Title"
#define PUSHER_TEST_NOTIFICATION_SUBTITLE @"Subtitle"
#define PUSHER_TEST_NOTIFICATION_MESSAGE @"Message"
#define PUSHER_TEST_NOTIFICATION_APP_NAME @"Settings"
#define PUSHER_TEST_NOTIFICATION_SECTION_ID @"com.apple.Preferences"

#define PUSHER_TEST_PUSH_RESULT_PREFIX @"Test Notification Result: "

#define PUSHER_SUFFICIENT_ALLOW_NOTIFICATIONS_KEY @"AllowNotifications"
#define PUSHER_SUFFICIENT_LOCK_SCREEN_KEY @"LockScreen"
#define PUSHER_SUFFICIENT_NOTIFICATION_CENTER_KEY @"NotificationCenter"
#define PUSHER_SUFFICIENT_BANNERS_KEY @"Banners"
#define PUSHER_SUFFICIENT_BADGES_KEY @"Badges"
#define PUSHER_SUFFICIENT_SOUNDS_KEY @"Sounds"
#define PUSHER_SUFFICIENT_SHOWS_PREVIEWS_KEY @"ShowsPreviews"

#define PUSHER_SNS_KEYS                                                        \
  @{                                                                           \
    PUSHER_SUFFICIENT_ALLOW_NOTIFICATIONS_KEY : @YES,                          \
    PUSHER_SUFFICIENT_LOCK_SCREEN_KEY : @NO,                                   \
    PUSHER_SUFFICIENT_NOTIFICATION_CENTER_KEY : @NO,                           \
    PUSHER_SUFFICIENT_BANNERS_KEY : @NO,                                       \
    PUSHER_SUFFICIENT_BADGES_KEY : @NO,                                        \
    PUSHER_SUFFICIENT_SOUNDS_KEY : @NO,                                        \
    PUSHER_SUFFICIENT_SHOWS_PREVIEWS_KEY : @NO                                 \
  }

#define NSPPreferenceCustomServicesKey @"CustomServices"
#define NSPPreferenceCustomServiceCustomAppsKey(service)                       \
  [NSString stringWithFormat:@"CustomService_%@_CustomApps", service]
#define NSPPreferenceCustomServiceBLPrefix(service)                            \
  [NSString stringWithFormat:@"CustomServiceBL_%@-", service]
// IF ADDING MORE CUSTOM SERVICE KEY CALCULATORS, REMEMBER TO RENAME THEM UPON
// CUSTOM SERVICE RENAME IN SERVICE LIST

// Built-in services are stored as one nested object per service under this
// single top-level key: BuiltInServices[serviceName] = { field : value, ... }.
#define NSPPreferenceBuiltInServicesKey @"BuiltInServices"

// Global (non-service) settings that used to be flat keys now live in one
// nested object under this key: Global = { appList : [...], appListIsBlacklist
// : BOOL }. NSPPreferenceGlobalBLPrefix is kept only for migrating the legacy
// flat `GlobalBL-<appID>` keys.
#define NSPPreferenceGlobalKey @"Global"

// Generic per-service field names (shared across all built-in services).
#define NSPPreferenceServiceEnabledKey @"enabled"
#define NSPPreferenceServiceTokenKey @"token"
#define NSPPreferenceServiceUserKey @"user"
#define NSPPreferenceServiceKeyKey @"key"
#define NSPPreferenceServiceEventNameKey @"eventName"
#define NSPPreferenceServiceDBNameKey @"dbName"
#define NSPPreferenceServiceServerURLKey @"serverURL"
#define NSPPreferenceServiceCorpidKey @"corpid"
#define NSPPreferenceServiceCorpsecretKey @"corpsecret"
#define NSPPreferenceServiceAgentIDKey @"agentID"
#define NSPPreferenceServiceTouserKey @"touser"
#define NSPPreferenceServiceDateFormatKey @"dateFormat"
#define NSPPreferenceServiceIncludeIconKey @"includeIcon"
#define NSPPreferenceServiceIncludeImageKey @"includeImage"
#define NSPPreferenceServiceCurateDataKey @"curateData"
#define NSPPreferenceServiceImageMaxWidthKey @"imageMaxWidth"
#define NSPPreferenceServiceImageMaxHeightKey @"imageMaxHeight"
#define NSPPreferenceServiceImageShrinkFactorKey @"imageShrinkFactor"
#define NSPPreferenceServiceSoundsKey @"sounds"
#define NSPPreferenceServiceDevicesKey @"devices"
#define NSPPreferenceServiceAppListKey @"appList"
#define NSPPreferenceServiceAppListIsBlacklistKey @"appListIsBlacklist"
#define NSPPreferenceServiceCustomAppsKey @"customApps"
#define NSPPreferenceServiceWhenToPushKey @"whenToPush"
#define NSPPreferenceServiceWhatNetworkKey @"whatNetwork"
#define NSPPreferenceServiceSNSIsAndKey @"snsIsAnd"
#define NSPPreferenceServiceSNSRequireANWithORKey @"snsRequireANWithOR"

// Bark-specific optional push parameters (each maps to a JSON body key of the
// Bark push API; empty value = not configured).
#define NSPPreferenceBarkLevelKey @"level"
#define NSPPreferenceBarkVolumeKey @"volume"
#define NSPPreferenceBarkBadgeKey @"badge"
#define NSPPreferenceBarkCallKey @"call"
#define NSPPreferenceBarkAutoCopyKey @"autoCopy"
#define NSPPreferenceBarkSoundKey @"sound"
#define NSPPreferenceBarkImageKey @"image"
#define NSPPreferenceBarkGroupKey @"group"
#define NSPPreferenceBarkIsArchiveKey @"isArchive"
#define NSPPreferenceBarkTTLKey @"ttl"
#define NSPPreferenceBarkClickURLKey @"clickURL"
#define NSPPreferenceBarkActionKey @"action"
#define NSPPreferenceBarkIDKey @"id"
#define NSPPreferenceBarkDeleteKey @"delete"
