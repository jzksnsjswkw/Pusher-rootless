#import "NSPushConfig.h"
#import "NSPushService.h"
#import "../Generated/BuiltinServices.generated.h"
#import "NSPushConstants.h"
#import "helpers.h"
#import <notify.h>

// Guarded prefs value accessors. Prefs plists can carry values of any class
// (hand-edited, legacy flat keys, migration leftovers), and messaging
// .boolValue/.intValue on the wrong class raises "unrecognized selector",
// crashing SpringBoard on the push hot path. NSNumber and NSString are
// accepted; anything else falls back to a safe default (NO / NSIntegerMin for
// invalid values). For integer prefs, NSString must represent a complete
// integer literal: partial or non-numeric strings ("abc", "12x") are treated
// as invalid instead of silently parsing to 0.
static BOOL NSPrefsBool(id value) {
  if ([value isKindOfClass:NSNumber.class] ||
      [value isKindOfClass:NSString.class]) {
    return [value boolValue];
  }
  return NO;
}

static BOOL NSPrefsBoolResolved(id value, BOOL defaultValue) {
  if ([value isKindOfClass:NSNumber.class] ||
      [value isKindOfClass:NSString.class]) {
    return [value boolValue];
  }
  return defaultValue;
}

static NSInteger NSPrefsInt(id value) {
  if ([value isKindOfClass:NSNumber.class]) {
    return [value integerValue];
  }
  if ([value isKindOfClass:NSString.class]) {
    NSString* stringValue = [(NSString*)value
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if (stringValue.length == 0) {
      return NSIntegerMin;
    }
    NSScanner* scanner = [NSScanner scannerWithString:stringValue];
    NSInteger result = 0;
    if ([scanner scanInteger:&result] && [scanner isAtEnd]) {
      return result;
    }
  }
  return NSIntegerMin;
}

// Resolves a prefs integer to a real default, treating both invalid values and
// the "-1 means default" segment-cell sentinel as "use default".
static NSInteger NSPrefsIntResolved(id value, NSInteger defaultValue) {
  NSInteger v = NSPrefsInt(value);
  return (v == NSIntegerMin || v == PUSHER_SEGMENT_CELL_DEFAULT) ? defaultValue : v;
}

static NSDictionary* NSPrefsDictionary(id value) {
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSArray* NSPrefsArray(id value) {
  return [value isKindOfClass:NSArray.class] ? value : nil;
}

static NSString* NSPrefsString(id value, NSString* defaultValue) {
  return [value isKindOfClass:NSString.class] ? (NSString*)value : defaultValue;
}

@interface NSPushServiceConfig ()
@property(nonatomic, readwrite, copy) NSString* name;
@property(nonatomic, readwrite) BOOL isCustomService;
@property(nonatomic, readwrite, copy) NSDictionary* rawPrefs;
@end

@implementation NSPushServiceConfig

+ (instancetype)configWithName:(NSString*)name
                      rawPrefs:(NSDictionary*)rawPrefs
               isCustomService:(BOOL)isCustomService {
  NSPushServiceConfig* config = [NSPushServiceConfig new];
  config.name = name;
  config.rawPrefs = rawPrefs;
  config.isCustomService = isCustomService;
  return config;
}

- (NSArray*)appList {
  return self.rawPrefs[@"appList"];
}

- (BOOL)appListIsBlacklist {
  return NSPrefsBoolResolved(self.rawPrefs[@"appListIsBlacklist"], YES);
}

- (NSArray*)sns {
  return self.rawPrefs[@"sns"];
}

- (BOOL)snsIsAnd {
  return NSPrefsBoolResolved(self.rawPrefs[@"snsIsAnd"], YES);
}

- (BOOL)snsRequireANWithOR {
  return NSPrefsBoolResolved(self.rawPrefs[@"snsRequireANWithOR"], YES);
}

- (NSInteger)whenToPush {
  return NSPrefsIntResolved(self.rawPrefs[@"whenToPush"],
                            PUSHER_WHEN_TO_PUSH_EITHER);
}

- (NSInteger)whatNetwork {
  return NSPrefsIntResolved(self.rawPrefs[@"whatNetwork"],
                            PUSHER_WHAT_NETWORK_ANY);
}

- (NSDictionary*)customApps {
  return self.rawPrefs[@"customApps"];
}

- (NSPushServiceConfig*)effectiveConfigForAppID:(NSString*)appID {
  // The service app-list filter in NSPushFilter compares case-sensitively
  // against the current appID, matching the exact-case bundle IDs stored by
  // the UI. Per-app override lookup is kept case-insensitive as a separate
  // tolerance layer: customApps may have been entered with a different case
  // (or migrated from older lowercased storage), so we still apply the
  // override when only the case differs.
  NSDictionary* customApps =
      [self.customApps isKindOfClass:NSDictionary.class]
          ? (NSDictionary*)self.customApps
          : nil;
  NSDictionary* customApp = nil;
  NSString* lookupAppID = [appID isKindOfClass:NSString.class]
                              ? appID.lowercaseString
                              : @"";
  if (customApps[lookupAppID]) {
    customApp = customApps[lookupAppID];
  } else {
    // Also tolerate custom apps stored with the original (possibly mixed) case.
    for (id storedAppID in customApps) {
      if ([storedAppID isKindOfClass:NSString.class] &&
          [((NSString*)storedAppID).lowercaseString
              isEqualToString:lookupAppID]) {
        customApp = customApps[storedAppID];
        break;
      }
    }
  }
  if (![customApp isKindOfClass:NSDictionary.class]) {
    return self;
  }
  NSMutableDictionary* merged = [self.rawPrefs mutableCopy];
  for (id key in customApp) {
    if ([key isKindOfClass:NSString.class]) {
      merged[key] = customApp[key];
    }
  }
  return [NSPushServiceConfig configWithName:self.name
                                    rawPrefs:merged
                             isCustomService:self.isCustomService];
}

@end

@interface NSPushConfigSnapshot ()
@property(nonatomic, readwrite) BOOL enabled;
@property(nonatomic, readwrite) NSInteger whenToPush;
@property(nonatomic, readwrite) NSInteger whatNetwork;
@property(nonatomic, readwrite) BOOL globalAppListIsBlacklist;
@property(nonatomic, readwrite, copy) NSArray* globalAppList;
@property(nonatomic, readwrite) BOOL snsIsAnd;
@property(nonatomic, readwrite) BOOL snsRequireANWithOR;
@property(nonatomic, readwrite, copy) NSDictionary* serviceConfigs;
@property(nonatomic, readwrite, copy) NSArray* enabledServiceNames;
@end

@implementation NSPushConfigSnapshot

+ (instancetype)snapshotWithEnabled:(BOOL)enabled
                         whenToPush:(NSInteger)whenToPush
                        whatNetwork:(NSInteger)whatNetwork
           globalAppListIsBlacklist:(BOOL)globalAppListIsBlacklist
                      globalAppList:(NSArray*)globalAppList
                           snsIsAnd:(BOOL)snsIsAnd
                 snsRequireANWithOR:(BOOL)snsRequireANWithOR
                     serviceConfigs:(NSDictionary*)serviceConfigs
                enabledServiceNames:(NSArray*)enabledServiceNames {
  NSPushConfigSnapshot* snapshot = [NSPushConfigSnapshot new];
  snapshot.enabled = enabled;
  snapshot.whenToPush = whenToPush;
  snapshot.whatNetwork = whatNetwork;
  snapshot.globalAppListIsBlacklist = globalAppListIsBlacklist;
  snapshot.globalAppList = globalAppList;
  snapshot.snsIsAnd = snsIsAnd;
  snapshot.snsRequireANWithOR = snsRequireANWithOR;
  snapshot.serviceConfigs = serviceConfigs;
  snapshot.enabledServiceNames = enabledServiceNames;
  return snapshot;
}

@end

static NSArray* getAppIDsWithPrefix(NSDictionary* prefs, NSString* prefix) {
  NSMutableArray* keys = [NSMutableArray new];
  for (id key in prefs.allKeys) {
    if (![key isKindOfClass:NSString.class]) {
      continue;
    }
    if ([key hasPrefix:prefix] && NSPrefsBool(prefs[key])) {
      NSString* subKey = [key substringFromIndex:prefix.length];
      // Keep the original case: app IDs are stored (GlobalBL-<appID> flat
      // keys, AltList applicationIdentifier) in their exact bundle-ID case,
      // and the matching side compares case-sensitively against
      // bulletin.sectionID, which is also the original-case bundle ID.
      [keys addObject:subKey];
    }
  }
  return keys;
}

static NSArray* getSNSKeys(NSDictionary* prefs, NSString* prefix,
                           NSDictionary* backupPrefs, NSString* backupPrefix) {
  NSMutableArray* keys = [NSMutableArray new];
  NSDictionary* pusherDefaultSNSKeys = PUSHER_SNS_KEYS;
  for (NSString* snsKey in pusherDefaultSNSKeys.allKeys) {
    NSString* key = XStr(@"%@%@", prefix, snsKey);
    id val = prefs[key];
    if (val) {
      if (NSPrefsBool(val)) {
        [keys addObject:snsKey];
      }
      continue;
    } else if (!val && backupPrefs) {
      NSString* backupKey = XStr(@"%@%@", backupPrefix, snsKey);
      if (backupPrefs[backupKey]) {
        if (NSPrefsBool(backupPrefs[backupKey])) {
          [keys addObject:snsKey];
        }
        continue;
      }
    }
    if (!val && pusherDefaultSNSKeys[snsKey] &&
        NSPrefsBool(pusherDefaultSNSKeys[snsKey])) {
      [keys addObject:snsKey];
    }
  }
  return keys;
}

// Migrate the legacy flat-per-service key scheme (e.g. `PushoverToken`,
// `BarkServerURL`, `PushoverBL-<appid>`=YES) into the new one-service-one-
// object layout stored under NSPPreferenceBuiltInServicesKey. Always scans for
// flat keys even when BuiltInServices already exists, so an empty/stale
// BuiltInServices object cannot strand old flat data. Returns a (copy of the)
// prefs dict with BuiltInServices filled and the migrated flat keys removed.
// Global (non-service) keys and custom services are left untouched.
static NSDictionary* migrateLegacyBuiltInServices(NSDictionary* prefs) {
  // Always scan for legacy flat keys, even when a (possibly empty or stale)
  // BuiltInServices object already exists, so old flat data is still folded
  // in and removed instead of being stranded forever.
  NSMutableDictionary* builtInServices = [NSMutableDictionary new];
  id existingBuiltIn = prefs[NSPPreferenceBuiltInServicesKey];
  if ([existingBuiltIn isKindOfClass:NSDictionary.class]) {
    [builtInServices addEntriesFromDictionary:(NSDictionary*)existingBuiltIn];
  }

  BOOL migratedAny = NO;
  NSMutableArray* allKeysToRemove = [NSMutableArray new];

  for (NSString* service in BUILTIN_PUSHER_SERVICES) {
    // Legacy key basenames (flat `<service><Field>` keys).
    NSArray* legacyKeys = @[
      XStr(@"%@Enabled", service),
      XStr(@"%@Token", service),
      XStr(@"%@User", service),
      XStr(@"%@Key", service),
      XStr(@"%@EventName", service),
      XStr(@"%@DateFormat", service),
      XStr(@"%@ServerURL", service),
      XStr(@"%@DBName", service),
      XStr(@"%@AppListIsBlacklist", service),
      XStr(@"%@WhenToPush", service),
      XStr(@"%@WhatNetwork", service),
      XStr(@"%@SufficientNotificationSettingsIsAnd", service),
      XStr(@"%@SNSORRequireAllowNotifications", service),
      XStr(@"%@Devices", service),
      XStr(@"%@Sounds", service),
      XStr(@"%@CustomApps", service),
      XStr(@"%@IncludeIcon", service),
      XStr(@"%@CurateData", service),
      XStr(@"%@IncludeImage", service),
      XStr(@"%@ImageMaxWidth", service),
      XStr(@"%@ImageMaxHeight", service),
      XStr(@"%@ImageShrinkFactor", service),
      XStr(@"%@Corpid", service),
      XStr(@"%@Corpsecret", service),
      XStr(@"%@AgentID", service),
      XStr(@"%@Touser", service)
    ];

    BOOL hasLegacy = NO;
    for (NSString* key in legacyKeys) {
      if (prefs[key] != nil) {
        hasLegacy = YES;
        break;
      }
    }
    // Also treat an app-list BL set as legacy data.
    if (!hasLegacy &&
        [getAppIDsWithPrefix(prefs, XStr(@"%@BL-", service)) count] > 0) {
      hasLegacy = YES;
    }
    if (!hasLegacy) {
      continue;
    }

    migratedAny = YES;

    // Start from the existing nested object (if any) and only fill missing
    // values from flat legacy keys, so an existing newer config is preserved.
    NSMutableDictionary* serviceObj = [NSMutableDictionary new];
    id existingServiceObj = builtInServices[service];
    if ([existingServiceObj isKindOfClass:NSDictionary.class]) {
      [serviceObj addEntriesFromDictionary:(NSDictionary*)existingServiceObj];
    }

    id flatEnabled = prefs[XStr(@"%@Enabled", service)];
    if (flatEnabled && !serviceObj[NSPPreferenceServiceEnabledKey]) {
      serviceObj[NSPPreferenceServiceEnabledKey] = flatEnabled;
    } else if (!serviceObj[NSPPreferenceServiceEnabledKey]) {
      serviceObj[NSPPreferenceServiceEnabledKey] = @NO;
    }

    id v;
#define MIGRATE_FIELD(field, legacy)                                           \
  v = prefs[(legacy)];                                                         \
  if (v && !serviceObj[(field)])                                               \
  serviceObj[(field)] = v

    MIGRATE_FIELD(NSPPreferenceServiceTokenKey, XStr(@"%@Token", service));
    MIGRATE_FIELD(NSPPreferenceServiceUserKey, XStr(@"%@User", service));
    MIGRATE_FIELD(NSPPreferenceServiceKeyKey, XStr(@"%@Key", service));
    MIGRATE_FIELD(NSPPreferenceServiceEventNameKey,
                  XStr(@"%@EventName", service));
    MIGRATE_FIELD(NSPPreferenceServiceDateFormatKey,
                  XStr(@"%@DateFormat", service));
    MIGRATE_FIELD(NSPPreferenceServiceServerURLKey,
                  XStr(@"%@ServerURL", service));
    MIGRATE_FIELD(NSPPreferenceServiceDBNameKey, XStr(@"%@DBName", service));
    MIGRATE_FIELD(NSPPreferenceServiceIncludeIconKey,
                  XStr(@"%@IncludeIcon", service));
    MIGRATE_FIELD(NSPPreferenceServiceCurateDataKey,
                  XStr(@"%@CurateData", service));
    MIGRATE_FIELD(NSPPreferenceServiceIncludeImageKey,
                  XStr(@"%@IncludeImage", service));
    MIGRATE_FIELD(NSPPreferenceServiceImageMaxWidthKey,
                  XStr(@"%@ImageMaxWidth", service));
    MIGRATE_FIELD(NSPPreferenceServiceImageMaxHeightKey,
                  XStr(@"%@ImageMaxHeight", service));
    MIGRATE_FIELD(NSPPreferenceServiceImageShrinkFactorKey,
                  XStr(@"%@ImageShrinkFactor", service));
    MIGRATE_FIELD(NSPPreferenceServiceCorpidKey, XStr(@"%@Corpid", service));
    MIGRATE_FIELD(NSPPreferenceServiceCorpsecretKey,
                  XStr(@"%@Corpsecret", service));
    MIGRATE_FIELD(NSPPreferenceServiceAgentIDKey, XStr(@"%@AgentID", service));
    MIGRATE_FIELD(NSPPreferenceServiceTouserKey, XStr(@"%@Touser", service));
    MIGRATE_FIELD(NSPPreferenceServiceDevicesKey, XStr(@"%@Devices", service));
    MIGRATE_FIELD(NSPPreferenceServiceSoundsKey, XStr(@"%@Sounds", service));
    MIGRATE_FIELD(NSPPreferenceServiceCustomAppsKey,
                  XStr(@"%@CustomApps", service));
#undef MIGRATE_FIELD

    // appListIsBlacklist defaults to YES; only a non-default NO is migrated.
    v = prefs[XStr(@"%@AppListIsBlacklist", service)];
    if (v && !serviceObj[NSPPreferenceServiceAppListIsBlacklistKey] &&
        !NSPrefsBoolResolved(v, YES)) {
      serviceObj[NSPPreferenceServiceAppListIsBlacklistKey] = v;
    }

    // whenToPush / whatNetwork / snsIsAnd / snsRequireANWithOR
    v = prefs[XStr(@"%@WhenToPush", service)];
    if (v && !serviceObj[NSPPreferenceServiceWhenToPushKey])
      serviceObj[NSPPreferenceServiceWhenToPushKey] = v;
    v = prefs[XStr(@"%@WhatNetwork", service)];
    if (v && !serviceObj[NSPPreferenceServiceWhatNetworkKey])
      serviceObj[NSPPreferenceServiceWhatNetworkKey] = v;
    v = prefs[XStr(@"%@SufficientNotificationSettingsIsAnd", service)];
    if (v && !serviceObj[@"SufficientNotificationSettingsIsAnd"])
      serviceObj[@"SufficientNotificationSettingsIsAnd"] = v;
    v = prefs[XStr(@"%@SNSORRequireAllowNotifications", service)];
    if (v && !serviceObj[@"SNSORRequireAllowNotifications"])
      serviceObj[@"SNSORRequireAllowNotifications"] = v;

    // SNS toggles
    NSDictionary* snsDefaults = PUSHER_SNS_KEYS;
    for (NSString* snsKey in snsDefaults.allKeys) {
      NSString* snsField = XStr(@"SNS-%@", snsKey);
      v = prefs[XStr(@"%@SNS-%@", service, snsKey)];
      if (v && !serviceObj[snsField]) {
        serviceObj[snsField] = v;
      }
    }

    // app list: merge flat `<service>BL-<appid>`=YES into any existing array.
    NSArray* flatAppList = getAppIDsWithPrefix(prefs, XStr(@"%@BL-", service));
    if (flatAppList.count > 0) {
      id existingAppListValue = serviceObj[NSPPreferenceServiceAppListKey];
      NSMutableArray* mergedAppList = [NSMutableArray arrayWithArray:
          [existingAppListValue isKindOfClass:NSArray.class]
              ? (NSArray*)existingAppListValue
              : @[]];
      for (NSString* appID in flatAppList) {
        if (![mergedAppList containsObject:appID]) {
          [mergedAppList addObject:appID];
        }
      }
      serviceObj[NSPPreferenceServiceAppListKey] = mergedAppList;
    }

    builtInServices[service] = serviceObj;

    // Collect the flat legacy keys for this service so they can be removed.
    for (NSString* p in legacyKeys) {
      if (prefs[p] != nil && ![allKeysToRemove containsObject:p]) {
        [allKeysToRemove addObject:p];
      }
    }
    for (NSString* key in prefs.allKeys) {
      if (![key isKindOfClass:NSString.class]) {
        continue;
      }
      if (([key hasPrefix:XStr(@"%@BL-", service)] ||
           [key hasPrefix:XStr(@"%@SNS-", service)]) &&
          ![allKeysToRemove containsObject:key]) {
        [allKeysToRemove addObject:key];
      }
    }
  }

  if (!migratedAny || allKeysToRemove.count == 0) {
    return prefs;
  }

  NSMutableDictionary* newPrefs = [prefs mutableCopy];
  newPrefs[NSPPreferenceBuiltInServicesKey] = builtInServices;
  for (NSString* key in allKeysToRemove) {
    [newPrefs removeObjectForKey:key];
  }

  CFPreferencesSetMultiple((__bridge CFDictionaryRef)newPrefs,
                           (__bridge CFArrayRef)allKeysToRemove, PUSHER_APP_ID,
                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);

  notify_post(PUSHER_PREFS_NOTIFICATION);
  XLog(@"Migrated legacy built-in service prefs");
  return newPrefs;
}
static NSDictionary* migrateLegacyCustomServices(NSDictionary* prefs) {
  // Scan the top-level keys for legacy flat custom-service data instead of
  // iterating CustomServices: the flat keys (CustomService_<name>_CustomApps,
  // CustomServiceBL_<name>-<appID>=YES) must be cleaned up even when the
  // service no longer exists or the caller's CustomServices snapshot is
  // stale (e.g. a cached copy without the service), otherwise the orphan keys
  // linger forever.
  NSMutableSet* legacyNames = [NSMutableSet new];
  NSString* customAppsPrefix = @"CustomService_";
  NSString* customAppsSuffix = @"_CustomApps";
  NSString* blKeyPrefix = @"CustomServiceBL_";
  for (NSString* key in prefs.allKeys) {
    if (![key isKindOfClass:NSString.class]) {
      continue;
    }
    if ([key hasPrefix:customAppsPrefix] && [key hasSuffix:customAppsSuffix]) {
      [legacyNames addObject:[key substringWithRange:NSMakeRange(
          customAppsPrefix.length,
          key.length - customAppsPrefix.length - customAppsSuffix.length)]];
    } else if ([key hasPrefix:blKeyPrefix]) {
      NSString* rest = [key substringFromIndex:blKeyPrefix.length];
      NSRange dash = [rest rangeOfString:@"-"];
      if (dash.location != NSNotFound) {
        [legacyNames addObject:[rest substringToIndex:dash.location]];
      }
    }
  }
  if (legacyNames.count == 0) {
    return prefs;
  }

  BOOL migratedAny = NO;
  NSDictionary* rawCustomServices =
      NSPrefsDictionary(prefs[NSPPreferenceCustomServicesKey]);
  NSMutableDictionary* newCustomServices = [rawCustomServices ?: @{} mutableCopy];
  NSMutableArray* keysToRemove = [NSMutableArray new];

  for (NSString* service in legacyNames) {
    // Only fold data into services that still exist; orphan flat keys for
    // deleted services are removed outright.
    NSMutableDictionary* serviceObj = nil;
    if ([newCustomServices[service] isKindOfClass:NSDictionary.class]) {
      serviceObj = [newCustomServices[service] mutableCopy];
    }

    // Flat CustomService_<service>_CustomApps -> nested customApps.
    NSString* customAppsKey = NSPPreferenceCustomServiceCustomAppsKey(service);
    NSDictionary* flatCustomApps = prefs[customAppsKey];
    if (serviceObj && [flatCustomApps isKindOfClass:NSDictionary.class] &&
        flatCustomApps.count > 0) {
      NSDictionary* existingCustomApps =
          NSPrefsDictionary(serviceObj[NSPPreferenceServiceCustomAppsKey]);
      NSMutableDictionary* nestedCustomApps =
          [existingCustomApps ?: @{} mutableCopy];
      [nestedCustomApps addEntriesFromDictionary:flatCustomApps];
      serviceObj[NSPPreferenceServiceCustomAppsKey] = nestedCustomApps;
      migratedAny = YES;
    }
    [keysToRemove addObject:customAppsKey];

    // Flat CustomServiceBL_<service>-<appID>=YES -> nested appList array.
    NSString* blPrefix = NSPPreferenceCustomServiceBLPrefix(service);
    NSArray* flatAppList = getAppIDsWithPrefix(prefs, blPrefix);
    if (serviceObj && flatAppList.count > 0) {
      NSArray* existingAppList =
          NSPrefsArray(serviceObj[NSPPreferenceServiceAppListKey]);
      NSMutableArray* nestedAppList =
          [NSMutableArray arrayWithArray:existingAppList ?: @[]];
      for (NSString* appID in flatAppList) {
        if (![nestedAppList containsObject:appID]) {
          [nestedAppList addObject:appID];
        }
      }
      serviceObj[NSPPreferenceServiceAppListKey] = nestedAppList;
      migratedAny = YES;
    }
    for (NSString* key in prefs.allKeys) {
      if ([key isKindOfClass:NSString.class] && [key hasPrefix:blPrefix] &&
          ![keysToRemove containsObject:key]) {
        [keysToRemove addObject:key];
      }
    }

    if (serviceObj) {
      newCustomServices[service] = serviceObj;
    }
  }

  // Any actual flat keys to remove? (migratedAny only covers data moved into
  // nested storage; orphan-only cleanups still need to write back.)
  if (!migratedAny) {
    for (NSString* key in keysToRemove) {
      if (prefs[key] != nil) {
        migratedAny = YES;
        break;
      }
    }
  }
  if (!migratedAny) {
    return prefs;
  }

  NSMutableDictionary* newPrefs = [prefs mutableCopy];
  newPrefs[NSPPreferenceCustomServicesKey] = newCustomServices;
  for (NSString* key in keysToRemove) {
    [newPrefs removeObjectForKey:key];
  }

  CFPreferencesSetMultiple((__bridge CFDictionaryRef)newPrefs,
                           (__bridge CFArrayRef)keysToRemove, PUSHER_APP_ID,
                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);
  notify_post(PUSHER_PREFS_NOTIFICATION);
  XLog(@"Migrated legacy custom service prefs");
  return newPrefs;
}

// Migrate the legacy flat global app-list keys (`GlobalBL-<appID>`=YES and
// `GlobalAppListIsBlacklist`) into the nested Global = { appList : [...],
// appListIsBlacklist : BOOL } object. This scans the top-level flat keys
// instead of early-returning when Global already exists: flat keys written by
// an older build can coexist with a stale Global and must still be folded in
// and removed. A NO-value flat key is an orphan left by the old toggle
// behavior (which wrote NO instead of removing the entry); it is dropped along
// with the rest of the prefix.
static NSDictionary* migrateLegacyGlobal(NSDictionary* prefs) {
  NSMutableArray* keysToRemove = [NSMutableArray new];
  NSMutableArray* flatAppIDs = [NSMutableArray new];
  id isBlacklist = nil;
  for (NSString* key in prefs.allKeys) {
    if (![key isKindOfClass:NSString.class]) {
      continue;
    }
    if ([key hasPrefix:NSPPreferenceGlobalBLPrefix]) {
      if (NSPrefsBool(prefs[key])) {
        [flatAppIDs addObject:[key substringFromIndex:NSPPreferenceGlobalBLPrefix.length]];
      }
      [keysToRemove addObject:key];
    } else if ([key isEqualToString:@"GlobalAppListIsBlacklist"]) {
      isBlacklist = prefs[key];
      [keysToRemove addObject:key];
    }
  }
  if (keysToRemove.count == 0) {
    return prefs;
  }

  NSMutableDictionary* global = [([prefs[NSPPreferenceGlobalKey] isKindOfClass:NSDictionary.class]
                                      ? prefs[NSPPreferenceGlobalKey]
                                      : @{}) mutableCopy];
  NSArray* existingAppList =
      NSPrefsArray(global[NSPPreferenceServiceAppListKey]);
  NSMutableArray* appList =
      [NSMutableArray arrayWithArray:existingAppList ?: @[]];
  for (NSString* appID in flatAppIDs) {
    if (![appList containsObject:appID]) {
      [appList addObject:appID];
    }
  }
  if (appList.count > 0) {
    global[NSPPreferenceServiceAppListKey] = appList;
  }
  if (isBlacklist && !NSPrefsBoolResolved(isBlacklist, YES)) {
    global[NSPPreferenceServiceAppListIsBlacklistKey] = isBlacklist;
  } else if (isBlacklist) {
    [global removeObjectForKey:NSPPreferenceServiceAppListIsBlacklistKey];
  }

  NSMutableDictionary* newPrefs = [prefs mutableCopy];
  newPrefs[NSPPreferenceGlobalKey] = global;
  for (NSString* key in keysToRemove) {
    [newPrefs removeObjectForKey:key];
  }

  CFPreferencesSetMultiple((__bridge CFDictionaryRef)newPrefs,
                           (__bridge CFArrayRef)keysToRemove, PUSHER_APP_ID,
                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);
  notify_post(PUSHER_PREFS_NOTIFICATION);
  XLog(@"Migrated legacy global prefs");
  return newPrefs;
}

@implementation NSPushPrefs

+ (NSPushConfigSnapshot*)loadSnapshot {
  XLog(@"Reloading prefs");

  CFArrayRef keyList = CFPreferencesCopyKeyList(
      PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  NSDictionary* prefs = @{};
  if (keyList) {
    prefs = CFBridgingRelease(CFPreferencesCopyMultiple(
        keyList, PUSHER_APP_ID, kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost));
    if (!prefs) {
      prefs = @{};
    }
    CFRelease(keyList);
  }

  prefs = migrateLegacyBuiltInServices(prefs);
  prefs = migrateLegacyCustomServices(prefs);
  prefs = migrateLegacyGlobal(prefs);

  BOOL enabled = YES;
  NSInteger whenToPush = PUSHER_WHEN_TO_PUSH_EITHER;
  NSInteger whatNetwork = PUSHER_WHAT_NETWORK_ANY;
  BOOL globalAppListIsBlacklist = YES;
  BOOL snsIsAnd = YES;
  BOOL snsRequireANWithOR = YES;

  id val = prefs[@"Enabled"];
  enabled = NSPrefsBoolResolved(val, YES);
  val = prefs[@"WhenToPush"];
  whenToPush = NSPrefsIntResolved(val, PUSHER_WHEN_TO_PUSH_EITHER);
  val = prefs[@"WhatNetwork"];
  whatNetwork = NSPrefsIntResolved(val, PUSHER_WHAT_NETWORK_ANY);
  NSDictionary* global = prefs[NSPPreferenceGlobalKey];
  NSArray* globalAppList = @[];
  if ([global isKindOfClass:NSDictionary.class]) {
    val = global[NSPPreferenceServiceAppListIsBlacklistKey];
    globalAppListIsBlacklist = NSPrefsBoolResolved(val, YES);
    NSArray* nestedAppList = global[NSPPreferenceServiceAppListKey];
    if ([nestedAppList isKindOfClass:NSArray.class]) {
      globalAppList = nestedAppList;
    }
  }
  val = prefs[@"SufficientNotificationSettingsIsAnd"];
  snsIsAnd = NSPrefsBoolResolved(val, YES);
  val = prefs[@"SNSORRequireAllowNotifications"];
  snsRequireANWithOR = NSPrefsBoolResolved(val, YES);

  NSMutableDictionary* serviceConfigs = [NSMutableDictionary new];
  NSMutableArray* enabledServiceNames = [NSMutableArray new];

  NSDictionary* customServices = NSPrefsDictionary(prefs[NSPPreferenceCustomServicesKey]);
  NSDictionary* builtInServices =
      NSPrefsDictionary(prefs[NSPPreferenceBuiltInServicesKey]) ?: @{};
  for (NSString* service in [[customServices allKeys]
           sortedArrayUsingSelector:@selector(compare:)]) {
    NSDictionary* customService = NSPrefsDictionary(customServices[service]);
    if (!customService) {
      continue;
    }
    NSMutableDictionary* servicePrefs = [customService mutableCopy];

    servicePrefs[@"isCustomService"] = @YES;
    servicePrefs[@"url"] = NSPrefsString(servicePrefs[@"url"], @"");
    servicePrefs[@"key"] = NSPrefsString(servicePrefs[@"key"], @"");
    servicePrefs[@"paramName"] =
        NSPrefsString(servicePrefs[@"paramName"], @"");
    servicePrefs[@"appListIsBlacklist"] =
        @(NSPrefsBoolResolved(servicePrefs[@"appListIsBlacklist"], YES));
    servicePrefs[@"appList"] =
        NSPrefsArray(customService[NSPPreferenceServiceAppListKey]) ?: @[];
    servicePrefs[@"whenToPush"] = @(NSPrefsIntResolved(
        servicePrefs[@"whenToPush"], whenToPush));
    servicePrefs[@"whatNetwork"] = @(NSPrefsIntResolved(
        servicePrefs[@"whatNetwork"], whatNetwork));
    servicePrefs[@"snsIsAnd"] = @(NSPrefsBoolResolved(
        servicePrefs[@"SufficientNotificationSettingsIsAnd"], snsIsAnd));
    servicePrefs[@"snsRequireANWithOR"] = @(NSPrefsBoolResolved(
        servicePrefs[@"SNSORRequireAllowNotifications"], snsRequireANWithOR));
    servicePrefs[@"sns"] = getSNSKeys(customService, NSPPreferenceSNSPrefix,
                                      prefs, NSPPreferenceSNSPrefix);

    NSDictionary* prefCustomApps =
        NSPrefsDictionary(customService[NSPPreferenceServiceCustomAppsKey]);
    NSMutableDictionary* customApps = [NSMutableDictionary new];
    for (NSString* customAppID in prefCustomApps.allKeys) {
      if (![customAppID isKindOfClass:NSString.class]) {
        continue;
      }
      NSDictionary* customAppPrefs = NSPrefsDictionary(prefCustomApps[customAppID]);
      if (!customAppPrefs) {
        continue;
      }
      // Skip disabled per-app overrides, mirroring the built-in service loop:
      // default enabled, so only an explicit NO is skipped.
      if (customAppPrefs[@"enabled"] &&
          !NSPrefsBoolResolved(customAppPrefs[@"enabled"], YES)) {
        continue;
      }

      NSMutableDictionary* customAppIDPref = [customAppPrefs mutableCopy];
      if (customAppPrefs[@"devices"] != nil) {
        NSArray* customAppDevices = NSPrefsArray(customAppPrefs[@"devices"]);
        NSMutableArray* customAppEnabledDevices = [NSMutableArray new];
        for (NSDictionary* customAppDevice in customAppDevices ?: @[]) {
          if (![customAppDevice isKindOfClass:NSDictionary.class]) {
            continue;
          }
          if (NSPrefsBool(customAppDevice[@"enabled"])) {
            [customAppEnabledDevices addObject:customAppDevice];
          }
        }
        customAppIDPref[@"devices"] = customAppEnabledDevices;
      }
      if (customAppPrefs[@"sounds"] != nil) {
        NSArray* customAppSounds = NSPrefsArray(customAppPrefs[@"sounds"]);
        NSMutableArray* customAppEnabledSounds = [NSMutableArray new];
        for (NSDictionary* customAppSound in customAppSounds ?: @[]) {
          if (![customAppSound isKindOfClass:NSDictionary.class] ||
              !customAppSound[@"id"]) {
            continue;
          }
          if (NSPrefsBool(customAppSound[@"enabled"])) {
            [customAppEnabledSounds addObject:customAppSound[@"id"]];
          }
        }
        customAppIDPref[@"sounds"] = customAppEnabledSounds;
      }
      customApps[customAppID] = [customAppIDPref copy];
    }

    servicePrefs[@"customApps"] = [customApps copy];

    NSPushServiceConfig* config =
        [NSPushServiceConfig configWithName:service
                                   rawPrefs:servicePrefs
                            isCustomService:YES];
    serviceConfigs[service] = config;

    if (customService[@"Enabled"] == nil || !NSPrefsBool(customService[@"Enabled"])) {
    } else {
      [enabledServiceNames addObject:service];
    }
  }

  for (NSString* service in BUILTIN_PUSHER_SERVICES) {
    NSDictionary* serviceObj = NSPrefsDictionary(builtInServices[service]) ?: @{};
    NSMutableDictionary* servicePrefs = [NSMutableDictionary new];

    servicePrefs[@"appList"] = NSPrefsArray(serviceObj[@"appList"]) ?: @[];
    servicePrefs[@"appListIsBlacklist"] =
        @(NSPrefsBoolResolved(serviceObj[@"appListIsBlacklist"], YES));
    servicePrefs[@"token"] = NSPrefsString(serviceObj[@"token"], @"");
    servicePrefs[@"user"] = NSPrefsString(serviceObj[@"user"], @"");
    servicePrefs[@"key"] = NSPrefsString(serviceObj[@"key"], @"");
    NSString* eventName = NSPrefsString(serviceObj[@"eventName"], @"");
    NSString* dbName = [[NSPrefsString(serviceObj[@"dbName"], @"")
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]]
        copy];
    servicePrefs[@"dateFormat"] =
        NSPrefsString(serviceObj[@"dateFormat"], @"");
    NSString* serverURL = NSPrefsString(serviceObj[@"serverURL"], @"");
    servicePrefs[@"url"] =
        [(Class<NSPPushService>)[NSPushServiceManager serviceClassForName:service]
            urlForEventName:eventName
                      dbName:dbName
                   serverURL:serverURL];
    servicePrefs[@"whenToPush"] = @(NSPrefsIntResolved(
        serviceObj[@"whenToPush"], whenToPush));
    servicePrefs[@"whatNetwork"] = @(NSPrefsIntResolved(
        serviceObj[@"whatNetwork"], whatNetwork));
    servicePrefs[@"snsIsAnd"] = @(NSPrefsBoolResolved(
        serviceObj[@"SufficientNotificationSettingsIsAnd"]
            ?: serviceObj[@"snsIsAnd"],
        snsIsAnd));
    servicePrefs[@"snsRequireANWithOR"] = @(NSPrefsBoolResolved(
        serviceObj[@"SNSORRequireAllowNotifications"]
            ?: serviceObj[@"snsRequireANWithOR"],
        snsRequireANWithOR));
    servicePrefs[@"sns"] = getSNSKeys(serviceObj, NSPPreferenceSNSPrefix, prefs,
                                      NSPPreferenceSNSPrefix);

    [servicePrefs addEntriesFromDictionary:[[NSPushServiceManager
                                               serviceClassForName:service]
                                               extraPrefsForName:service
                                                    servicePrefs:serviceObj]];

    NSArray* devices = NSPrefsArray(serviceObj[@"devices"]) ?: @[];
    NSMutableArray* enabledDevices = [NSMutableArray new];
    for (NSDictionary* device in devices) {
      // Guard against malformed entries so SpringBoard can't crash on a
      // missing/mistyped device dict.
      if (![device isKindOfClass:NSDictionary.class]) {
        continue;
      }
      if (NSPrefsBool(device[@"enabled"])) {
        [enabledDevices addObject:device];
      }
    }
    servicePrefs[@"devices"] = enabledDevices;

    NSArray* sounds = NSPrefsArray(serviceObj[@"sounds"]) ?: @[];
    NSMutableArray* enabledSounds = [NSMutableArray new];
    for (NSDictionary* sound in sounds) {
      if (![sound isKindOfClass:NSDictionary.class] || !sound[@"id"]) {
        continue;
      }
      if (NSPrefsBool(sound[@"enabled"])) {
        [enabledSounds addObject:sound[@"id"]];
      }
    }
    servicePrefs[@"sounds"] = enabledSounds;

    NSDictionary* prefCustomApps =
        NSPrefsDictionary(serviceObj[@"customApps"]);
    NSMutableDictionary* customApps = [NSMutableDictionary new];
    for (NSString* customAppID in prefCustomApps.allKeys) {
      if (![customAppID isKindOfClass:NSString.class]) {
        continue;
      }
      NSDictionary* customAppPrefs = NSPrefsDictionary(prefCustomApps[customAppID]);
      if (!customAppPrefs) {
        continue;
      }
      if (customAppPrefs[@"enabled"] &&
          !NSPrefsBoolResolved(customAppPrefs[@"enabled"], YES)) {
        continue;
      }

      NSArray* customAppDevices = NSPrefsArray(customAppPrefs[@"devices"]) ?: @[];
      NSMutableArray* customAppEnabledDevices = [NSMutableArray new];
      for (NSDictionary* customAppDevice in customAppDevices) {
        if (![customAppDevice isKindOfClass:NSDictionary.class]) {
          continue;
        }
        if (NSPrefsBool(customAppDevice[@"enabled"])) {
          [customAppEnabledDevices addObject:customAppDevice];
        }
      }

      NSArray* customAppSounds = NSPrefsArray(customAppPrefs[@"sounds"]) ?: @[];
      NSMutableArray* customAppEnabledSounds = [NSMutableArray new];
      for (NSDictionary* customAppSound in customAppSounds) {
        if (![customAppSound isKindOfClass:NSDictionary.class] ||
            !customAppSound[@"id"]) {
          continue;
        }
        if (NSPrefsBool(customAppSound[@"enabled"])) {
          [customAppEnabledSounds addObject:customAppSound[@"id"]];
        }
      }

      NSString* customAppEventName =
          NSPrefsString(customAppPrefs[@"eventName"], eventName);
      NSString* customServerURL =
          NSPrefsString(customAppPrefs[@"serverURL"], serverURL);
      NSString* customAppUrl =
          [(Class<NSPPushService>)[NSPushServiceManager serviceClassForName:service]
              urlForEventName:customAppEventName
                        dbName:dbName
                     serverURL:customServerURL];

      NSMutableDictionary* customAppIDPref = [@{
        @"devices" : customAppEnabledDevices,
        @"sounds" : customAppEnabledSounds
      } mutableCopy];

      if (!XEq(customAppUrl, servicePrefs[@"url"])) {
        customAppIDPref[@"url"] = customAppUrl;
      }

      [customAppIDPref addEntriesFromDictionary:
                           [[NSPushServiceManager serviceClassForName:service]
                               extraCustomAppPrefsForName:service
                                                 appPrefs:customAppPrefs]];

      customApps[customAppID] = customAppIDPref;
    }
    servicePrefs[@"customApps"] = [customApps copy];

    NSPushServiceConfig* config =
        [NSPushServiceConfig configWithName:service
                                   rawPrefs:servicePrefs
                            isCustomService:NO];
    serviceConfigs[service] = config;

    if (serviceObj[@"enabled"] == nil || !NSPrefsBool(serviceObj[@"enabled"])) {
    } else {
      [enabledServiceNames addObject:service];
    }
  }

  XLog(@"Reloaded");

  return [NSPushConfigSnapshot snapshotWithEnabled:enabled
                                        whenToPush:whenToPush
                                       whatNetwork:whatNetwork
                          globalAppListIsBlacklist:globalAppListIsBlacklist
                                     globalAppList:globalAppList
                                          snsIsAnd:snsIsAnd
                                snsRequireANWithOR:snsRequireANWithOR
                                    serviceConfigs:serviceConfigs
                               enabledServiceNames:enabledServiceNames];
}

@end
