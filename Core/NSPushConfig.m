#import "NSPushConfig.h"
#import "NSPushService.h"
#import "../Generated/BuiltinServices.generated.h"
#import "NSPushPrefsMigration.h"
#import "NSPushConstants.h"
#import "../Shared/NSPushPrefsStore.h"
#import "helpers.h"

// Guarded prefs value accessors live in helpers.h (NSPushBoolValue /
// NSPushBoolResolved / NSPushIntegerValue / NSPushIntegerValueStrict /
// NSPushIntegerValueResolved / NSPushStringValue / NSPushDictionaryValue /
// NSPushArrayValue) so the "don't message boolValue/intValue on an arbitrary
// prefs plist class" policy has a single home across Core, Core/Services and
// Preferences.

static NSArray* getSNSKeys(NSDictionary* prefs, NSString* prefix,
                           NSDictionary* backupPrefs, NSString* backupPrefix) {
  NSMutableArray* keys = [NSMutableArray new];
  NSDictionary* pusherDefaultSNSKeys = PUSHER_SNS_KEYS;
  for (NSString* snsKey in pusherDefaultSNSKeys.allKeys) {
    NSString* key = XStr(@"%@%@", prefix, snsKey);
    id val = prefs[key];
    if (val) {
      if (NSPushBoolValue(val)) {
        [keys addObject:snsKey];
      }
      continue;
    } else if (!val && backupPrefs) {
      NSString* backupKey = XStr(@"%@%@", backupPrefix, snsKey);
      if (backupPrefs[backupKey]) {
        if (NSPushBoolValue(backupPrefs[backupKey])) {
          [keys addObject:snsKey];
        }
        continue;
      }
    }
    if (!val && pusherDefaultSNSKeys[snsKey] &&
        NSPushBoolValue(pusherDefaultSNSKeys[snsKey])) {
      [keys addObject:snsKey];
    }
  }
  return keys;
}

@implementation NSPushPrefs

+ (NSPushConfigSnapshot*)loadSnapshot {
  XLog(@"Reloading prefs");

  NSDictionary* prefs = [NSPushPrefsStore snapshot];

  prefs = NSPushMigrateLegacyBuiltInServices(prefs);
  prefs = NSPushMigrateLegacyCustomServices(prefs);
  prefs = NSPushMigrateLegacyGlobal(prefs);

  BOOL enabled = YES;
  NSInteger whenToPush = PUSHER_WHEN_TO_PUSH_EITHER;
  NSInteger whatNetwork = PUSHER_WHAT_NETWORK_ANY;
  BOOL globalAppListIsBlacklist = YES;
  BOOL snsIsAnd = YES;
  BOOL snsRequireANWithOR = YES;

  id val = prefs[@"Enabled"];
  enabled = NSPushBoolResolved(val, YES);
  val = prefs[@"WhenToPush"];
  whenToPush = NSPushIntegerValueResolved(val, PUSHER_WHEN_TO_PUSH_EITHER);
  val = prefs[@"WhatNetwork"];
  whatNetwork = NSPushIntegerValueResolved(val, PUSHER_WHAT_NETWORK_ANY);
  NSDictionary* global = prefs[NSPPreferenceGlobalKey];
  NSArray* globalAppList = @[];
  if ([global isKindOfClass:NSDictionary.class]) {
    val = global[NSPPreferenceServiceAppListIsBlacklistKey];
    globalAppListIsBlacklist = NSPushBoolResolved(val, YES);
    NSArray* nestedAppList = global[NSPPreferenceServiceAppListKey];
    if ([nestedAppList isKindOfClass:NSArray.class]) {
      globalAppList = nestedAppList;
    }
  }
  val = prefs[@"SufficientNotificationSettingsIsAnd"];
  snsIsAnd = NSPushBoolResolved(val, YES);
  val = prefs[@"SNSORRequireAllowNotifications"];
  snsRequireANWithOR = NSPushBoolResolved(val, YES);

  NSMutableDictionary* serviceConfigs = [NSMutableDictionary new];
  NSMutableArray* enabledServiceNames = [NSMutableArray new];

  NSDictionary* customServices = NSPushDictionaryValue(prefs[NSPPreferenceCustomServicesKey]);
  NSDictionary* builtInServices =
      NSPushDictionaryValue(prefs[NSPPreferenceBuiltInServicesKey]) ?: @{};
  for (NSString* service in [[customServices allKeys]
           sortedArrayUsingSelector:@selector(compare:)]) {
    NSDictionary* customService = NSPushDictionaryValue(customServices[service]);
    if (!customService) {
      continue;
    }
    NSMutableDictionary* servicePrefs = [customService mutableCopy];

    servicePrefs[@"isCustomService"] = @YES;
    servicePrefs[@"url"] = NSPushStringValue(servicePrefs[@"url"], @"");
    servicePrefs[@"key"] = NSPushStringValue(servicePrefs[@"key"], @"");
    servicePrefs[@"paramName"] =
        NSPushStringValue(servicePrefs[@"paramName"], @"");
    servicePrefs[@"appListIsBlacklist"] =
        @(NSPushBoolResolved(servicePrefs[@"appListIsBlacklist"], YES));
    servicePrefs[@"appList"] =
        NSPushArrayValue(customService[NSPPreferenceServiceAppListKey]) ?: @[];
    servicePrefs[@"whenToPush"] = @(NSPushIntegerValueResolved(
        servicePrefs[@"whenToPush"], whenToPush));
    servicePrefs[@"whatNetwork"] = @(NSPushIntegerValueResolved(
        servicePrefs[@"whatNetwork"], whatNetwork));
    servicePrefs[@"snsIsAnd"] = @(NSPushBoolResolved(
        servicePrefs[@"SufficientNotificationSettingsIsAnd"], snsIsAnd));
    servicePrefs[@"snsRequireANWithOR"] = @(NSPushBoolResolved(
        servicePrefs[@"SNSORRequireAllowNotifications"], snsRequireANWithOR));
    servicePrefs[@"sns"] = getSNSKeys(customService, NSPPreferenceSNSPrefix,
                                      prefs, NSPPreferenceSNSPrefix);

    NSDictionary* prefCustomApps =
        NSPushDictionaryValue(customService[NSPPreferenceServiceCustomAppsKey]);
    NSMutableDictionary* customApps = [NSMutableDictionary new];
    for (NSString* customAppID in prefCustomApps.allKeys) {
      if (![customAppID isKindOfClass:NSString.class]) {
        continue;
      }
      NSDictionary* customAppPrefs = NSPushDictionaryValue(prefCustomApps[customAppID]);
      if (!customAppPrefs) {
        continue;
      }
      // Skip disabled per-app overrides, mirroring the built-in service loop:
      // default enabled, so only an explicit NO is skipped.
      if (customAppPrefs[@"enabled"] &&
          !NSPushBoolResolved(customAppPrefs[@"enabled"], YES)) {
        continue;
      }

      NSMutableDictionary* customAppIDPref = [customAppPrefs mutableCopy];
      if (customAppPrefs[@"devices"] != nil) {
        NSArray* customAppDevices = NSPushArrayValue(customAppPrefs[@"devices"]);
        NSMutableArray* customAppEnabledDevices = [NSMutableArray new];
        for (NSDictionary* customAppDevice in customAppDevices ?: @[]) {
          if (![customAppDevice isKindOfClass:NSDictionary.class]) {
            continue;
          }
          if (NSPushBoolValue(customAppDevice[@"enabled"])) {
            [customAppEnabledDevices addObject:customAppDevice];
          }
        }
        customAppIDPref[@"devices"] = customAppEnabledDevices;
      }
      if (customAppPrefs[@"sounds"] != nil) {
        NSArray* customAppSounds = NSPushArrayValue(customAppPrefs[@"sounds"]);
        NSMutableArray* customAppEnabledSounds = [NSMutableArray new];
        for (NSDictionary* customAppSound in customAppSounds ?: @[]) {
          if (![customAppSound isKindOfClass:NSDictionary.class] ||
              !customAppSound[@"id"]) {
            continue;
          }
          if (NSPushBoolValue(customAppSound[@"enabled"])) {
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

    if (customService[@"Enabled"] == nil || !NSPushBoolValue(customService[@"Enabled"])) {
    } else {
      [enabledServiceNames addObject:service];
    }
  }

  for (NSString* service in BUILTIN_PUSHER_SERVICES) {
    NSDictionary* serviceObj = NSPushDictionaryValue(builtInServices[service]) ?: @{};
    NSMutableDictionary* servicePrefs = [NSMutableDictionary new];

    servicePrefs[@"appList"] = NSPushArrayValue(serviceObj[@"appList"]) ?: @[];
    servicePrefs[@"appListIsBlacklist"] =
        @(NSPushBoolResolved(serviceObj[@"appListIsBlacklist"], YES));
    servicePrefs[@"token"] = NSPushStringValue(serviceObj[@"token"], @"");
    servicePrefs[@"user"] = NSPushStringValue(serviceObj[@"user"], @"");
    servicePrefs[@"key"] = NSPushStringValue(serviceObj[@"key"], @"");
    NSString* eventName = NSPushStringValue(serviceObj[@"eventName"], @"");
    NSString* dbName = [[NSPushStringValue(serviceObj[@"dbName"], @"")
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]]
        copy];
    servicePrefs[@"dateFormat"] =
        NSPushStringValue(serviceObj[@"dateFormat"], @"");
    NSString* serverURL = NSPushStringValue(serviceObj[@"serverURL"], @"");
    servicePrefs[@"url"] =
        [(Class<NSPPushService>)[NSPushServiceManager serviceClassForName:service]
            urlForEventName:eventName
                      dbName:dbName
                   serverURL:serverURL];
    servicePrefs[@"whenToPush"] = @(NSPushIntegerValueResolved(
        serviceObj[@"whenToPush"], whenToPush));
    servicePrefs[@"whatNetwork"] = @(NSPushIntegerValueResolved(
        serviceObj[@"whatNetwork"], whatNetwork));
    servicePrefs[@"snsIsAnd"] = @(NSPushBoolResolved(
        serviceObj[@"SufficientNotificationSettingsIsAnd"]
            ?: serviceObj[@"snsIsAnd"],
        snsIsAnd));
    servicePrefs[@"snsRequireANWithOR"] = @(NSPushBoolResolved(
        serviceObj[@"SNSORRequireAllowNotifications"]
            ?: serviceObj[@"snsRequireANWithOR"],
        snsRequireANWithOR));
    servicePrefs[@"sns"] = getSNSKeys(serviceObj, NSPPreferenceSNSPrefix, prefs,
                                      NSPPreferenceSNSPrefix);

    [servicePrefs addEntriesFromDictionary:[[NSPushServiceManager
                                               serviceClassForName:service]
                                               extraPrefsForName:service
                                                    servicePrefs:serviceObj]];

    NSArray* devices = NSPushArrayValue(serviceObj[@"devices"]) ?: @[];
    NSMutableArray* enabledDevices = [NSMutableArray new];
    for (NSDictionary* device in devices) {
      // Guard against malformed entries so SpringBoard can't crash on a
      // missing/mistyped device dict.
      if (![device isKindOfClass:NSDictionary.class]) {
        continue;
      }
      if (NSPushBoolValue(device[@"enabled"])) {
        [enabledDevices addObject:device];
      }
    }
    servicePrefs[@"devices"] = enabledDevices;

    NSArray* sounds = NSPushArrayValue(serviceObj[@"sounds"]) ?: @[];
    NSMutableArray* enabledSounds = [NSMutableArray new];
    for (NSDictionary* sound in sounds) {
      if (![sound isKindOfClass:NSDictionary.class] || !sound[@"id"]) {
        continue;
      }
      if (NSPushBoolValue(sound[@"enabled"])) {
        [enabledSounds addObject:sound[@"id"]];
      }
    }
    servicePrefs[@"sounds"] = enabledSounds;

    NSDictionary* prefCustomApps =
        NSPushDictionaryValue(serviceObj[@"customApps"]);
    NSMutableDictionary* customApps = [NSMutableDictionary new];
    for (NSString* customAppID in prefCustomApps.allKeys) {
      if (![customAppID isKindOfClass:NSString.class]) {
        continue;
      }
      NSDictionary* customAppPrefs = NSPushDictionaryValue(prefCustomApps[customAppID]);
      if (!customAppPrefs) {
        continue;
      }
      if (customAppPrefs[@"enabled"] &&
          !NSPushBoolResolved(customAppPrefs[@"enabled"], YES)) {
        continue;
      }

      NSArray* customAppDevices = NSPushArrayValue(customAppPrefs[@"devices"]) ?: @[];
      NSMutableArray* customAppEnabledDevices = [NSMutableArray new];
      for (NSDictionary* customAppDevice in customAppDevices) {
        if (![customAppDevice isKindOfClass:NSDictionary.class]) {
          continue;
        }
        if (NSPushBoolValue(customAppDevice[@"enabled"])) {
          [customAppEnabledDevices addObject:customAppDevice];
        }
      }

      NSArray* customAppSounds = NSPushArrayValue(customAppPrefs[@"sounds"]) ?: @[];
      NSMutableArray* customAppEnabledSounds = [NSMutableArray new];
      for (NSDictionary* customAppSound in customAppSounds) {
        if (![customAppSound isKindOfClass:NSDictionary.class] ||
            !customAppSound[@"id"]) {
          continue;
        }
        if (NSPushBoolValue(customAppSound[@"enabled"])) {
          [customAppEnabledSounds addObject:customAppSound[@"id"]];
        }
      }

      NSString* customAppEventName =
          NSPushStringValue(customAppPrefs[@"eventName"], eventName);
      NSString* customServerURL =
          NSPushStringValue(customAppPrefs[@"serverURL"], serverURL);
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

    if (serviceObj[@"enabled"] == nil || !NSPushBoolValue(serviceObj[@"enabled"])) {
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
