#import "NSPushPrefsMigration.h"
#import "NSPushConstants.h"
#import "../Generated/BuiltinServices.generated.h"
#import "../Shared/NSPushPrefsStore.h"
#import "helpers.h"

static NSArray* getAppIDsWithPrefix(NSDictionary* prefs, NSString* prefix) {
  NSMutableArray* keys = [NSMutableArray new];
  for (id key in prefs.allKeys) {
    if (![key isKindOfClass:NSString.class]) {
      continue;
    }
    if ([key hasPrefix:prefix] && NSPushBoolValue(prefs[key])) {
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

// Migrate the legacy flat-per-service key scheme (e.g. `PushoverToken`,
// `BarkServerURL`, `PushoverBL-<appid>`=YES) into the new one-service-one-
// object layout stored under NSPPreferenceBuiltInServicesKey. Always scans for
// flat keys even when BuiltInServices already exists, so an empty/stale
// BuiltInServices object cannot strand old flat data. Returns a (copy of the)
// prefs dict with BuiltInServices filled and the migrated flat keys removed.
// Global (non-service) keys and custom services are left untouched.
NSDictionary* NSPushMigrateLegacyBuiltInServices(NSDictionary* prefs) {
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
        !NSPushBoolResolved(v, YES)) {
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

  [NSPushPrefsStore applySnapshot:newPrefs
                       removeKeys:allKeysToRemove
                     shouldNotify:YES];
  XLog(@"Migrated legacy built-in service prefs");
  return newPrefs;
}
NSDictionary* NSPushMigrateLegacyCustomServices(NSDictionary* prefs) {
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
      NSPushDictionaryValue(prefs[NSPPreferenceCustomServicesKey]);
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
          NSPushDictionaryValue(serviceObj[NSPPreferenceServiceCustomAppsKey]);
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
          NSPushArrayValue(serviceObj[NSPPreferenceServiceAppListKey]);
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

  [NSPushPrefsStore applySnapshot:newPrefs
                       removeKeys:keysToRemove
                     shouldNotify:YES];
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
NSDictionary* NSPushMigrateLegacyGlobal(NSDictionary* prefs) {
  NSMutableArray* keysToRemove = [NSMutableArray new];
  NSMutableArray* flatAppIDs = [NSMutableArray new];
  id isBlacklist = nil;
  for (NSString* key in prefs.allKeys) {
    if (![key isKindOfClass:NSString.class]) {
      continue;
    }
    if ([key hasPrefix:NSPPreferenceGlobalBLPrefix]) {
      if (NSPushBoolValue(prefs[key])) {
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
      NSPushArrayValue(global[NSPPreferenceServiceAppListKey]);
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
  if (isBlacklist && !NSPushBoolResolved(isBlacklist, YES)) {
    global[NSPPreferenceServiceAppListIsBlacklistKey] = isBlacklist;
  } else if (isBlacklist) {
    [global removeObjectForKey:NSPPreferenceServiceAppListIsBlacklistKey];
  }

  NSMutableDictionary* newPrefs = [prefs mutableCopy];
  newPrefs[NSPPreferenceGlobalKey] = global;
  for (NSString* key in keysToRemove) {
    [newPrefs removeObjectForKey:key];
  }

  [NSPushPrefsStore applySnapshot:newPrefs
                       removeKeys:keysToRemove
                     shouldNotify:YES];
  XLog(@"Migrated legacy global prefs");
  return newPrefs;
}

