#import "NSPushConfig.h"
#import "NSPushService.h"
#import "../Generated/BuiltinServices.generated.h"
#import "NSPushConstants.h"
#import "helpers.h"
#import <notify.h>

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
  return ((NSNumber*)self.rawPrefs[@"appListIsBlacklist"]).boolValue;
}

- (NSArray*)sns {
  return self.rawPrefs[@"sns"];
}

- (BOOL)snsIsAnd {
  return ((NSNumber*)self.rawPrefs[@"snsIsAnd"]).boolValue;
}

- (BOOL)snsRequireANWithOR {
  return ((NSNumber*)self.rawPrefs[@"snsRequireANWithOR"]).boolValue;
}

- (NSInteger)whenToPush {
  return ((NSNumber*)self.rawPrefs[@"whenToPush"]).intValue;
}

- (NSInteger)whatNetwork {
  return ((NSNumber*)self.rawPrefs[@"whatNetwork"]).intValue;
}

- (NSDictionary*)customApps {
  return self.rawPrefs[@"customApps"];
}

- (NSPushServiceConfig*)effectiveConfigForAppID:(NSString*)appID {
  // appList matching is done against lowercased app IDs (see
  // NSPushFilter.appListReasonIfAnyWithConfig:), so look up the per-app
  // override case-insensitively too; otherwise a custom app entered with a
  // different case silently never applies.
  NSDictionary* customApp = nil;
  NSString* lookupAppID = appID.lowercaseString;
  if (self.customApps[lookupAppID]) {
    customApp = self.customApps[lookupAppID];
  } else {
    // Also tolerate custom apps stored with the original (possibly mixed) case.
    for (NSString* storedAppID in self.customApps) {
      if ([storedAppID.lowercaseString isEqualToString:lookupAppID]) {
        customApp = self.customApps[storedAppID];
        break;
      }
    }
  }
  if (!customApp) {
    return self;
  }
  NSMutableDictionary* merged = [self.rawPrefs mutableCopy];
  for (NSString* key in customApp) {
    merged[key] = customApp[key];
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
    if ([key hasPrefix:prefix] && ((NSNumber*)prefs[key]).boolValue) {
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
      if (((NSNumber*)val).boolValue) {
        [keys addObject:snsKey];
      }
      continue;
    } else if (!val && backupPrefs) {
      NSString* backupKey = XStr(@"%@%@", backupPrefix, snsKey);
      if (backupPrefs[backupKey]) {
        if (((NSNumber*)backupPrefs[backupKey]).boolValue) {
          [keys addObject:snsKey];
        }
        continue;
      }
    }
    if (!val && pusherDefaultSNSKeys[snsKey] &&
        ((NSNumber*)pusherDefaultSNSKeys[snsKey]).boolValue) {
      [keys addObject:snsKey];
    }
  }
  return keys;
}

// Migrate the legacy flat-per-service key scheme (e.g. `PushoverToken`,
// `BarkServerURL`, `PushoverBL-<appid>`=YES) into the new one-service-one-
// object layout stored under NSPPreferenceBuiltInServicesKey. Runs once:
// if the new key already exists the migration is a no-op. Returns a (copy of
// the) prefs dict with BuiltInServices filled and the migrated flat keys
// removed. Global (non-service) keys and custom services are left untouched.
static NSDictionary* migrateLegacyBuiltInServices(NSDictionary* prefs) {
  if (prefs[NSPPreferenceBuiltInServicesKey] != nil) {
    return prefs; // already migrated
  }

  BOOL migratedAny = NO;
  NSMutableDictionary* builtInServices = [NSMutableDictionary new];

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
    NSMutableDictionary* serviceObj = [NSMutableDictionary new];

    serviceObj[NSPPreferenceServiceEnabledKey] =
        prefs[XStr(@"%@Enabled", service)] ?: @NO;
    id v;
#define MIGRATE_FIELD(field, legacy)                                           \
  v = prefs[(legacy)];                                                         \
  if (v)                                                                       \
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
    // appListIsBlacklist defaults to YES; only a non-default NO is migrated,
    // a YES value is dropped with the flat keys.
    v = prefs[XStr(@"%@AppListIsBlacklist", service)];
    if (v && !((NSNumber*)v).boolValue) {
      serviceObj[NSPPreferenceServiceAppListIsBlacklistKey] = v;
    }
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

    // whenToPush / whatNetwork / snsIsAnd / snsRequireANWithOR
    v = prefs[XStr(@"%@WhenToPush", service)];
    if (v)
      serviceObj[NSPPreferenceServiceWhenToPushKey] = v;
    v = prefs[XStr(@"%@WhatNetwork", service)];
    if (v)
      serviceObj[NSPPreferenceServiceWhatNetworkKey] = v;
    v = prefs[XStr(@"%@SufficientNotificationSettingsIsAnd", service)];
    if (v)
      serviceObj[@"SufficientNotificationSettingsIsAnd"] = v;
    v = prefs[XStr(@"%@SNSORRequireAllowNotifications", service)];
    if (v)
      serviceObj[@"SNSORRequireAllowNotifications"] = v;

    // SNS toggles
    NSDictionary* snsDefaults = PUSHER_SNS_KEYS;
    for (NSString* snsKey in snsDefaults.allKeys) {
      v = prefs[XStr(@"%@SNS-%@", service, snsKey)];
      if (v) {
        serviceObj[XStr(@"SNS-%@", snsKey)] = v;
      }
    }

    // app list: flat `<service>BL-<appid>`=YES -> array
    NSArray* appList = getAppIDsWithPrefix(prefs, XStr(@"%@BL-", service));
    serviceObj[NSPPreferenceServiceAppListKey] = appList;

    builtInServices[service] = serviceObj;
  }

  if (!migratedAny) {
    return prefs;
  }

  NSMutableDictionary* newPrefs = [prefs mutableCopy];
  newPrefs[NSPPreferenceBuiltInServicesKey] = builtInServices;

  // Remove the migrated flat per-service keys.
  NSMutableArray* keysToRemove = [NSMutableArray new];
  for (NSString* service in BUILTIN_PUSHER_SERVICES) {
    NSArray* prefixes = @[
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
    for (NSString* p in prefixes) {
      if (newPrefs[p] != nil) {
        [newPrefs removeObjectForKey:p];
        [keysToRemove addObject:p];
      }
    }
    // remove flat `<service>BL-<appid>` keys
    for (NSString* key in prefs.allKeys) {
      if ([key hasPrefix:XStr(@"%@BL-", service)] &&
          ![keysToRemove containsObject:key]) {
        [keysToRemove addObject:key];
      }
    }
    // remove flat `<service>SNS-<key>` keys
    for (NSString* key in prefs.allKeys) {
      if ([key hasPrefix:XStr(@"%@SNS-", service)] &&
          ![keysToRemove containsObject:key]) {
        [keysToRemove addObject:key];
      }
    }
  }

  if (keysToRemove.count) {
    for (NSString* key in keysToRemove) {
      [newPrefs removeObjectForKey:key];
    }
    CFPreferencesSetMultiple((__bridge CFDictionaryRef)newPrefs,
                             (__bridge CFArrayRef)keysToRemove, PUSHER_APP_ID,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
  } else {
    CFPreferencesSetValue((__bridge CFStringRef)NSPPreferenceBuiltInServicesKey,
                          (__bridge CFPropertyListRef)builtInServices,
                          PUSHER_APP_ID, kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
  }

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
  NSMutableDictionary* newCustomServices =
      [((NSDictionary*)prefs[NSPPreferenceCustomServicesKey] ?: @{}) mutableCopy];
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
      NSMutableDictionary* nestedCustomApps =
          [(serviceObj[NSPPreferenceServiceCustomAppsKey] ?: @{}) mutableCopy];
      [nestedCustomApps addEntriesFromDictionary:flatCustomApps];
      serviceObj[NSPPreferenceServiceCustomAppsKey] = nestedCustomApps;
      migratedAny = YES;
    }
    [keysToRemove addObject:customAppsKey];

    // Flat CustomServiceBL_<service>-<appID>=YES -> nested appList array.
    NSString* blPrefix = NSPPreferenceCustomServiceBLPrefix(service);
    NSArray* flatAppList = getAppIDsWithPrefix(prefs, blPrefix);
    if (serviceObj && flatAppList.count > 0) {
      NSMutableArray* nestedAppList = [NSMutableArray
          arrayWithArray:(serviceObj[NSPPreferenceServiceAppListKey] ?: @[])];
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
      if (((NSNumber*)prefs[key]).boolValue) {
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
  NSMutableArray* appList = [NSMutableArray
      arrayWithArray:(global[NSPPreferenceServiceAppListKey] ?: @[])];
  for (NSString* appID in flatAppIDs) {
    if (![appList containsObject:appID]) {
      [appList addObject:appID];
    }
  }
  if (appList.count > 0) {
    global[NSPPreferenceServiceAppListKey] = appList;
  }
  if (isBlacklist && !((NSNumber*)isBlacklist).boolValue) {
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
  enabled = val ? ((NSNumber*)val).boolValue : YES;
  val = prefs[@"WhenToPush"];
  whenToPush = val ? ((NSNumber*)val).intValue : PUSHER_WHEN_TO_PUSH_EITHER;
  val = prefs[@"WhatNetwork"];
  whatNetwork = val ? ((NSNumber*)val).intValue : PUSHER_WHAT_NETWORK_ANY;
  NSDictionary* global = prefs[NSPPreferenceGlobalKey];
  NSArray* globalAppList = @[];
  if ([global isKindOfClass:NSDictionary.class]) {
    val = global[NSPPreferenceServiceAppListIsBlacklistKey];
    globalAppListIsBlacklist = val ? ((NSNumber*)val).boolValue : YES;
    NSArray* nestedAppList = global[NSPPreferenceServiceAppListKey];
    if ([nestedAppList isKindOfClass:NSArray.class]) {
      globalAppList = nestedAppList;
    }
  }
  val = prefs[@"SufficientNotificationSettingsIsAnd"];
  snsIsAnd = val ? ((NSNumber*)val).boolValue : YES;
  val = prefs[@"SNSORRequireAllowNotifications"];
  snsRequireANWithOR = val ? ((NSNumber*)val).boolValue : YES;

  NSMutableDictionary* serviceConfigs = [NSMutableDictionary new];
  NSMutableArray* enabledServiceNames = [NSMutableArray new];

  NSDictionary* customServices = prefs[NSPPreferenceCustomServicesKey];
  NSDictionary* builtInServices = prefs[NSPPreferenceBuiltInServicesKey] ?: @{};
  for (NSString* service in [[customServices allKeys]
           sortedArrayUsingSelector:@selector(compare:)]) {
    NSDictionary* customService = customServices[service];
    NSMutableDictionary* servicePrefs = [customService mutableCopy];

    servicePrefs[@"isCustomService"] = @YES;
    servicePrefs[@"appListIsBlacklist"] =
        servicePrefs[@"appListIsBlacklist"] ?: @YES;
    servicePrefs[@"appList"] =
        customService[NSPPreferenceServiceAppListKey] ?: @[];
    servicePrefs[@"whenToPush"] =
        (!servicePrefs[@"whenToPush"] ||
         ((NSNumber*)servicePrefs[@"whenToPush"]).intValue ==
             PUSHER_SEGMENT_CELL_DEFAULT)
            ? @(whenToPush)
            : servicePrefs[@"whenToPush"];
    servicePrefs[@"whatNetwork"] =
        (!servicePrefs[@"whatNetwork"] ||
         ((NSNumber*)servicePrefs[@"whatNetwork"]).intValue ==
             PUSHER_SEGMENT_CELL_DEFAULT)
            ? @(whatNetwork)
            : servicePrefs[@"whatNetwork"];
    servicePrefs[@"snsIsAnd"] =
        servicePrefs[@"SufficientNotificationSettingsIsAnd"] ?: @(snsIsAnd);
    servicePrefs[@"snsRequireANWithOR"] =
        servicePrefs[@"SNSORRequireAllowNotifications"]
            ?: @(snsRequireANWithOR);
    servicePrefs[@"sns"] = getSNSKeys(customService, NSPPreferenceSNSPrefix,
                                      prefs, NSPPreferenceSNSPrefix);

    NSDictionary* prefCustomApps =
        (NSDictionary*)customService[NSPPreferenceServiceCustomAppsKey] ?: @{};
    NSMutableDictionary* customApps = [NSMutableDictionary new];
    for (NSString* customAppID in prefCustomApps.allKeys) {
      NSDictionary* customAppPrefs = prefCustomApps[customAppID];
      if (!customAppPrefs) {
        continue;
      }
      // Skip disabled per-app overrides, mirroring the built-in service loop:
      // default enabled, so only an explicit NO is skipped.
      if (customAppPrefs[@"enabled"] &&
          !((NSNumber*)customAppPrefs[@"enabled"]).boolValue) {
        continue;
      }
      customApps[customAppID] = [customAppPrefs copy];
    }

    servicePrefs[@"customApps"] = [customApps copy];

    NSPushServiceConfig* config =
        [NSPushServiceConfig configWithName:service
                                   rawPrefs:servicePrefs
                            isCustomService:YES];
    serviceConfigs[service] = config;

    if (customService[@"Enabled"] == nil ||
        !((NSNumber*)customService[@"Enabled"]).boolValue) {
    } else {
      [enabledServiceNames addObject:service];
    }
  }

  for (NSString* service in BUILTIN_PUSHER_SERVICES) {
    NSDictionary* serviceObj = builtInServices[service] ?: @{};
    NSMutableDictionary* servicePrefs = [NSMutableDictionary new];

    servicePrefs[@"appList"] = serviceObj[@"appList"] ?: @[];
    servicePrefs[@"appListIsBlacklist"] =
        serviceObj[@"appListIsBlacklist"] ?: @YES;
    servicePrefs[@"token"] = serviceObj[@"token"] ?: @"";
    servicePrefs[@"user"] = serviceObj[@"user"] ?: @"";
    servicePrefs[@"key"] = serviceObj[@"key"] ?: @"";
    NSString* eventName = serviceObj[@"eventName"] ?: @"";
    NSString* dbName = [[(serviceObj[@"dbName"] ?: @"")
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]]
        copy];
    servicePrefs[@"dateFormat"] = serviceObj[@"dateFormat"] ?: @"";
    NSString* serverURL = serviceObj[@"serverURL"] ?: @"";
    servicePrefs[@"url"] =
        [(Class<NSPPushService>)[NSPushServiceManager serviceClassForName:service]
            urlForEventName:eventName
                      dbName:dbName
                   serverURL:serverURL];
    servicePrefs[@"whenToPush"] =
        [(((NSNumber*)serviceObj[@"whenToPush"]).intValue ==
                  PUSHER_SEGMENT_CELL_DEFAULT
              ? @(whenToPush)
              : (serviceObj[@"whenToPush"] ?: @(whenToPush))) copy];
    servicePrefs[@"whatNetwork"] =
        [(((NSNumber*)serviceObj[@"whatNetwork"]).intValue ==
                  PUSHER_SEGMENT_CELL_DEFAULT
              ? @(whatNetwork)
              : (serviceObj[@"whatNetwork"] ?: @(whatNetwork))) copy];
    servicePrefs[@"snsIsAnd"] =
        (serviceObj[@"SufficientNotificationSettingsIsAnd"]
             ?: (serviceObj[@"snsIsAnd"] ?: @(snsIsAnd)));
    servicePrefs[@"snsRequireANWithOR"] =
        (serviceObj[@"SNSORRequireAllowNotifications"]
             ?: (serviceObj[@"snsRequireANWithOR"] ?: @(snsRequireANWithOR)));
    servicePrefs[@"sns"] = getSNSKeys(serviceObj, NSPPreferenceSNSPrefix, prefs,
                                      NSPPreferenceSNSPrefix);

    [servicePrefs addEntriesFromDictionary:[[NSPushServiceManager
                                               serviceClassForName:service]
                                               extraPrefsForName:service
                                                    servicePrefs:serviceObj]];

    NSArray* devices = serviceObj[@"devices"] ?: @[];
    NSMutableArray* enabledDevices = [NSMutableArray new];
    for (NSDictionary* device in devices) {
      // Guard against malformed entries so SpringBoard can't crash on a
      // missing/mistyped device dict.
      if (![device isKindOfClass:NSDictionary.class]) {
        continue;
      }
      if (((NSNumber*)device[@"enabled"]).boolValue) {
        [enabledDevices addObject:device];
      }
    }
    servicePrefs[@"devices"] = enabledDevices;

    NSArray* sounds = serviceObj[@"sounds"] ?: @[];
    NSMutableArray* enabledSounds = [NSMutableArray new];
    for (NSDictionary* sound in sounds) {
      if (![sound isKindOfClass:NSDictionary.class] || !sound[@"id"]) {
        continue;
      }
      if (((NSNumber*)sound[@"enabled"]).boolValue) {
        [enabledSounds addObject:sound[@"id"]];
      }
    }
    servicePrefs[@"sounds"] = enabledSounds;

    NSDictionary* prefCustomApps =
        (NSDictionary*)serviceObj[@"customApps"] ?: @{};
    NSMutableDictionary* customApps = [NSMutableDictionary new];
    for (NSString* customAppID in prefCustomApps.allKeys) {
      NSDictionary* customAppPrefs = prefCustomApps[customAppID];
      if (customAppPrefs[@"enabled"] &&
          !((NSNumber*)customAppPrefs[@"enabled"]).boolValue) {
        continue;
      }

      NSArray* customAppDevices = customAppPrefs[@"devices"] ?: @[];
      NSMutableArray* customAppEnabledDevices = [NSMutableArray new];
      for (NSDictionary* customAppDevice in customAppDevices) {
        if (![customAppDevice isKindOfClass:NSDictionary.class]) {
          continue;
        }
        if (((NSNumber*)customAppDevice[@"enabled"]).boolValue) {
          [customAppEnabledDevices addObject:customAppDevice];
        }
      }

      NSArray* customAppSounds = customAppPrefs[@"sounds"] ?: @[];
      NSMutableArray* customAppEnabledSounds = [NSMutableArray new];
      for (NSDictionary* customAppSound in customAppSounds) {
        if (![customAppSound isKindOfClass:NSDictionary.class] ||
            !customAppSound[@"id"]) {
          continue;
        }
        if (((NSNumber*)customAppSound[@"enabled"]).boolValue) {
          [customAppEnabledSounds addObject:customAppSound[@"id"]];
        }
      }

      NSString* customAppEventName = customAppPrefs[@"eventName"] ?: eventName;
      NSString* customServerURL = customAppPrefs[@"serverURL"] ?: serverURL;
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

    if (serviceObj[@"enabled"] == nil ||
        !((NSNumber*)serviceObj[@"enabled"]).boolValue) {
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
