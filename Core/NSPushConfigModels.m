#import "NSPushConfig.h"
#import "NSPushConstants.h"
#import "helpers.h"

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
  return NSPushBoolResolved(self.rawPrefs[@"appListIsBlacklist"], YES);
}

- (NSArray*)sns {
  return self.rawPrefs[@"sns"];
}

- (BOOL)snsIsAnd {
  return NSPushBoolResolved(self.rawPrefs[@"snsIsAnd"], YES);
}

- (BOOL)snsRequireANWithOR {
  return NSPushBoolResolved(self.rawPrefs[@"snsRequireANWithOR"], YES);
}

- (NSInteger)whenToPush {
  return NSPushIntegerValueResolved(self.rawPrefs[@"whenToPush"],
                            PUSHER_WHEN_TO_PUSH_EITHER);
}

- (NSInteger)whatNetwork {
  return NSPushIntegerValueResolved(self.rawPrefs[@"whatNetwork"],
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
