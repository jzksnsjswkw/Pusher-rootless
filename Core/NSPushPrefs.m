#import "NSPushPrefs.h"
#import "NSPushConfigSnapshot.h"
#import "NSPushServiceConfig.h"
#import "global.h"
#import "helpers.h"

// returns array of all lowercase keys that begin with the given prefix that
// have a boolean value of true in the dictionary
static NSArray* getAppIDsWithPrefix(NSDictionary* prefs, NSString* prefix) {
  NSMutableArray* keys = [NSMutableArray new];
  for (id key in prefs.allKeys) {
    if (![key isKindOfClass:NSString.class]) {
      continue;
    }
    if ([key hasPrefix:prefix] && ((NSNumber*)prefs[key]).boolValue) {
      NSString* subKey = [key substringFromIndex:prefix.length];
      [keys addObject:subKey.lowercaseString];
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
    // check default if val is nil, not if it's set to false
    if (!val && pusherDefaultSNSKeys[snsKey] &&
        ((NSNumber*)pusherDefaultSNSKeys[snsKey]).boolValue) {
      [keys addObject:snsKey];
    }
  }
  return keys;
}

static NSString* getServiceURL(NSString* service, NSDictionary* options) {
  if (XEq(service, PUSHER_SERVICE_PUSHOVER)) {
    return PUSHER_SERVICE_PUSHOVER_URL;
  } else if (XEq(service, PUSHER_SERVICE_PUSHBULLET)) {
    return PUSHER_SERVICE_PUSHBULLET_URL;
  } else if (XEq(service, PUSHER_SERVICE_IFTTT)) {
    return [PUSHER_SERVICE_IFTTT_URL
        stringByReplacingOccurrencesOfString:@"REPLACE_EVENT_NAME"
                                  withString:options[@"eventName"]];
  } else if (XEq(service, PUSHER_SERVICE_PUSHER_RECEIVER)) {
    return [PUSHER_SERVICE_PUSHER_RECEIVER_URL
        stringByReplacingOccurrencesOfString:@"REPLACE_DB_NAME"
                                  withString:options[@"dbName"]];
  } else if (XEq(service, PUSHER_SERVICE_FEISHU)) {
    return PUSHER_SERVICE_FEISHU_URL;
  } else if (XEq(service, PUSHER_SERVICE_BARK)) {
    NSString* serverURL = options[@"serverURL"];
    NSString* finalURL = nil;

    if (serverURL && serverURL.length > 0) {
      if ([serverURL hasSuffix:@"/"]) {
        finalURL = [serverURL stringByAppendingString:@"REPLACE_KEY"];
      } else {
        finalURL = [serverURL stringByAppendingFormat:@"/REPLACE_KEY"];
      }
    } else {
      finalURL = PUSHER_SERVICE_BARK_URL;
    }
    return finalURL;
  } else if (XEq(service, PUSHER_SERVICE_WECHAT)) {
    return PUSHER_SERVICE_WECHAT_URL;
  }
  return @"";
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
  val = prefs[@"GlobalAppListIsBlacklist"];
  globalAppListIsBlacklist = val ? ((NSNumber*)val).boolValue : YES;
  val = prefs[@"SufficientNotificationSettingsIsAnd"];
  snsIsAnd = val ? ((NSNumber*)val).boolValue : YES;
  val = prefs[@"SNSORRequireAllowNotifications"];
  snsRequireANWithOR = val ? ((NSNumber*)val).boolValue : YES;
  NSArray* globalAppList =
      getAppIDsWithPrefix(prefs, NSPPreferenceGlobalBLPrefix);
  NSArray* globalSNS = getSNSKeys(prefs, NSPPreferenceSNSPrefix, nil, nil);

  NSMutableDictionary* serviceConfigs = [NSMutableDictionary new];
  NSMutableArray* enabledServiceNames = [NSMutableArray new];

  NSDictionary* customServices = prefs[NSPPreferenceCustomServicesKey];
  for (NSString* service in [[customServices allKeys]
           sortedArrayUsingSelector:@selector(compare:)]) {
    NSDictionary* customService = customServices[service];
    NSMutableDictionary* servicePrefs = [customService mutableCopy];

    servicePrefs[@"isCustomService"] = @YES;
    servicePrefs[@"appList"] =
        getAppIDsWithPrefix(prefs, NSPPreferenceCustomServiceBLPrefix(service));
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

    NSString* customAppsKey = NSPPreferenceCustomServiceCustomAppsKey(service);

    // custom apps
    NSDictionary* prefCustomApps = (NSDictionary*)prefs[customAppsKey] ?: @{};
    NSMutableDictionary* customApps = [NSMutableDictionary new];
    for (NSString* customAppID in prefCustomApps.allKeys) {
      NSDictionary* customAppPrefs = prefCustomApps[customAppID];
      if (!customAppPrefs) {
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

    // default is service disabled
    if (customService[@"Enabled"] == nil ||
        !((NSNumber*)customService[@"Enabled"]).boolValue) {
      // skip if disabled
    } else {
      [enabledServiceNames addObject:service];
    }
  }

  for (NSString* service in BUILTIN_PUSHER_SERVICES) {
    NSMutableDictionary* servicePrefs = [NSMutableDictionary new];

    NSString* appListPrefix = XStr(@"%@BL-", service);
    NSString* tokenKey = XStr(@"%@Token", service);
    NSString* userKey = XStr(@"%@User", service);
    NSString* keyKey = XStr(@"%@Key", service);
    NSString* devicesKey = XStr(@"%@Devices", service);
    NSString* soundsKey = XStr(@"%@Sounds", service);
    NSString* serverURLKey = XStr(@"%@ServerURL", service);
    NSString* eventNameKey = XStr(@"%@EventName", service);
    NSString* dateFormatKey = XStr(@"%@DateFormat", service);
    NSString* customAppsKey = NSPPreferenceBuiltInServiceCustomAppsKey(service);
    NSString* appListIsBlacklistKey = XStr(@"%@AppListIsBlacklist", service);
    NSString* dbNameKey = XStr(@"%@DBName", service);
    NSString* whenToPushKey = XStr(@"%@WhenToPush", service);
    NSString* whatNetworkKey = XStr(@"%@WhatNetwork", service);
    NSString* snsIsAndKey =
        XStr(@"%@SufficientNotificationSettingsIsAnd", service);
    NSString* snsRequireANWithORKey =
        XStr(@"%@SNSORRequireAllowNotifications", service);
    NSString* snsPrefix = XStr(@"%@%@", service, NSPPreferenceSNSPrefix);

    servicePrefs[@"appList"] = getAppIDsWithPrefix(prefs, appListPrefix);
    val = prefs[appListIsBlacklistKey];
    servicePrefs[@"appListIsBlacklist"] = [(val ?: @YES) copy];
    val = prefs[tokenKey];
    servicePrefs[@"token"] = [(val ?: @"") copy];
    val = prefs[userKey];
    servicePrefs[@"user"] = [(val ?: @"") copy];
    val = prefs[keyKey];
    servicePrefs[@"key"] = [(val ?: @"") copy];
    val = prefs[eventNameKey];
    NSString* eventName = [(val ?: @"") copy];
    val = prefs[dbNameKey];
    NSString* dbName = [[(val ?: @"")
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]]
        copy];
    val = prefs[dateFormatKey];
    servicePrefs[@"dateFormat"] = [(val ?: @"") copy];
    val = prefs[serverURLKey];
    NSString* serverURL = [(val ?: @"") copy];
    servicePrefs[@"url"] = getServiceURL(service, @{
      @"eventName" : eventName,
      @"dbName" : dbName,
      @"serverURL" : serverURL
    });
    val = prefs[whenToPushKey];
    servicePrefs[@"whenToPush"] =
        val ?: @(whenToPush); // if not set, go with default
    servicePrefs[@"whenToPush"] =
        [(((NSNumber*)servicePrefs[@"whenToPush"]).intValue ==
                  PUSHER_SEGMENT_CELL_DEFAULT
              ? @(whenToPush)
              : servicePrefs[@"whenToPush"]) copy];
    val = prefs[whatNetworkKey];
    servicePrefs[@"whatNetwork"] =
        val ?: @(whatNetwork); // if not set, go with default
    servicePrefs[@"whatNetwork"] =
        [(((NSNumber*)servicePrefs[@"whatNetwork"]).intValue ==
                  PUSHER_SEGMENT_CELL_DEFAULT
              ? @(whatNetwork)
              : servicePrefs[@"whatNetwork"]) copy];
    val = prefs[snsIsAndKey];
    servicePrefs[@"snsIsAnd"] = [(val ?: @YES) copy];
    val = prefs[snsRequireANWithORKey];
    servicePrefs[@"snsRequireANWithOR"] = [(val ?: @YES) copy];
    servicePrefs[@"sns"] =
        getSNSKeys(prefs, snsPrefix, prefs, NSPPreferenceSNSPrefix);

    if (XEq(service, PUSHER_SERVICE_BARK)) {
      servicePrefs[@"serverURL"] =
          prefs[serverURLKey] ?: @"https://api.day.app";
    }

    if (XEq(service, PUSHER_SERVICE_IFTTT)) {
      NSString* includeIconKey = XStr(@"%@IncludeIcon", service);
      servicePrefs[@"includeIcon"] = prefs[includeIconKey] ?: @NO;

      NSString* curateDataKey = XStr(@"%@CurateData", service);
      servicePrefs[@"curateData"] = prefs[curateDataKey] ?: @YES;
    }

    if (XEq(service, PUSHER_SERVICE_PUSHER_RECEIVER)) {
      NSString* includeIconKey = XStr(@"%@IncludeIcon", service);
      servicePrefs[@"includeIcon"] = prefs[includeIconKey] ?: @YES;

      NSString* includeImageKey = XStr(@"%@IncludeImage", service);
      servicePrefs[@"includeImage"] = prefs[includeImageKey] ?: @YES;

      NSString* imageMaxWidthKey = XStr(@"%@ImageMaxWidth", service);
      servicePrefs[@"imageMaxWidth"] =
          prefs[imageMaxWidthKey] ?: @(PUSHER_DEFAULT_MAX_WIDTH);

      NSString* imageMaxHeightKey = XStr(@"%@ImageMaxHeight", service);
      servicePrefs[@"imageMaxHeight"] =
          prefs[imageMaxHeightKey] ?: @(PUSHER_DEFAULT_MAX_HEIGHT);

      NSString* imageShrinkFactorKey = XStr(@"%@ImageShrinkFactor", service);
      servicePrefs[@"imageShrinkFactor"] =
          prefs[imageShrinkFactorKey] ?: @(PUSHER_DEFAULT_SHRINK_FACTOR);
    }

    if (XEq(service, PUSHER_SERVICE_WECHAT)) {
      NSString* corpidKey = XStr(@"%@Corpid", service);
      servicePrefs[@"corpid"] = prefs[corpidKey] ?: @"";

      NSString* corpsecretKey = XStr(@"%@Corpsecret", service);
      servicePrefs[@"corpsecret"] = prefs[corpsecretKey] ?: @"";

      NSString* agentIDKey = XStr(@"%@AgentID", service);
      servicePrefs[@"agentID"] = prefs[agentIDKey] ?: @"";

      NSString* touserKey = XStr(@"%@Touser", service);
      servicePrefs[@"touser"] = prefs[touserKey] ?: @"";
    }

    // devices
    NSArray* devices = prefs[devicesKey] ?: @[];
    NSMutableArray* enabledDevices = [NSMutableArray new];
    for (NSDictionary* device in devices) {
      if (((NSNumber*)device[@"enabled"]).boolValue) {
        [enabledDevices addObject:device];
      }
    }
    servicePrefs[@"devices"] = enabledDevices;

    // sounds
    NSArray* sounds = prefs[soundsKey] ?: @[];
    NSMutableArray* enabledSounds = [NSMutableArray new];
    for (NSDictionary* sound in sounds) {
      if (((NSNumber*)sound[@"enabled"]).boolValue) {
        [enabledSounds addObject:sound[@"id"]];
      }
    }
    servicePrefs[@"sounds"] = enabledSounds;

    // custom apps
    NSDictionary* prefCustomApps = (NSDictionary*)prefs[customAppsKey] ?: @{};
    NSMutableDictionary* customApps = [NSMutableDictionary new];
    for (NSString* customAppID in prefCustomApps.allKeys) {
      NSDictionary* customAppPrefs = prefCustomApps[customAppID];
      // skip if custom app is disabled, default enabled so ignore bool check if
      // key doesn't exist
      if (customAppPrefs[@"enabled"] &&
          !((NSNumber*)customAppPrefs[@"enabled"]).boolValue) {
        continue;
      }

      NSArray* customAppDevices = customAppPrefs[@"devices"] ?: @{};
      NSMutableArray* customAppEnabledDevices = [NSMutableArray new];
      for (NSDictionary* customAppDevice in customAppDevices) {
        if (((NSNumber*)customAppDevice[@"enabled"]).boolValue) {
          [customAppEnabledDevices addObject:customAppDevice];
        }
      }

      NSArray* customAppSounds = customAppPrefs[@"sounds"] ?: @{};
      NSMutableArray* customAppEnabledSounds = [NSMutableArray new];
      for (NSDictionary* customAppSound in customAppSounds) {
        if (((NSNumber*)customAppSound[@"enabled"]).boolValue) {
          [customAppEnabledSounds addObject:customAppSound[@"id"]];
        }
      }

      NSString* customAppEventName = customAppPrefs[@"eventName"] ?: eventName;
      NSString* customServerURL = customAppPrefs[@"serverURL"] ?: serverURL;
      NSString* customAppUrl = getServiceURL(service, @{
        @"eventName" : customAppEventName,
        @"dbName" : dbName,
        @"serverURL" : customServerURL
      });

      NSMutableDictionary* customAppIDPref = [@{
        @"devices" : customAppEnabledDevices,
        @"sounds" : customAppEnabledSounds
      } mutableCopy];

      if (!XEq(customAppUrl, servicePrefs[@"url"])) {
        customAppIDPref[@"url"] = customAppUrl;
      }

      if (XEq(service, PUSHER_SERVICE_PUSHER_RECEIVER)) {
        customAppIDPref[@"includeIcon"] =
            customAppPrefs[@"includeIcon"] ?: @YES;
        customAppIDPref[@"includeImage"] =
            customAppPrefs[@"includeImage"] ?: @YES;
        customAppIDPref[@"imageMaxWidth"] =
            customAppPrefs[@"imageMaxWidth"] ?: @(PUSHER_DEFAULT_MAX_WIDTH);
        customAppIDPref[@"imageMaxHeight"] =
            customAppPrefs[@"imageMaxHeight"] ?: @(PUSHER_DEFAULT_MAX_HEIGHT);
        customAppIDPref[@"imageShrinkFactor"] =
            customAppPrefs[@"imageShrinkFactor"]
                ?: @(PUSHER_DEFAULT_SHRINK_FACTOR);
      }

      if (XEq(service, PUSHER_SERVICE_IFTTT)) {
        customAppIDPref[@"includeIcon"] = customAppPrefs[@"includeIcon"] ?: @NO;
        customAppIDPref[@"curateData"] = customAppPrefs[@"curateData"] ?: @YES;
      }

      if (XEq(service, PUSHER_SERVICE_WECHAT)) {
        customAppIDPref[@"touser"] = customAppPrefs[@"touser"] ?: @"";
      }

      customApps[customAppID] = customAppIDPref;
    }
    servicePrefs[@"customApps"] = [customApps copy];

    NSPushServiceConfig* config =
        [NSPushServiceConfig configWithName:service
                                   rawPrefs:servicePrefs
                            isCustomService:NO];
    serviceConfigs[service] = config;

    NSString* enabledKey = XStr(@"%@Enabled", service);
    // default is service disabled
    if (prefs[enabledKey] == nil || !((NSNumber*)prefs[enabledKey]).boolValue) {
      // skip if disabled
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
                                         globalSNS:(NSDictionary*)globalSNS
                                    serviceConfigs:serviceConfigs
                               enabledServiceNames:enabledServiceNames];
}

@end
