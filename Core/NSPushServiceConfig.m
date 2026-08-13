#import "NSPushServiceConfig.h"

@interface NSPushServiceConfig ()
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite) BOOL isCustomService;
@property (nonatomic, readwrite, copy) NSDictionary *rawPrefs;
@end

@implementation NSPushServiceConfig

+ (instancetype)configWithName:(NSString *)name
                      rawPrefs:(NSDictionary *)rawPrefs
               isCustomService:(BOOL)isCustomService {
  NSPushServiceConfig *config = [NSPushServiceConfig new];
  config.name = name;
  config.rawPrefs = rawPrefs;
  config.isCustomService = isCustomService;
  return config;
}

- (NSArray *)appList {
  return self.rawPrefs[@"appList"];
}

- (BOOL)appListIsBlacklist {
  return ((NSNumber *)self.rawPrefs[@"appListIsBlacklist"]).boolValue;
}

- (NSDictionary *)sns {
  return self.rawPrefs[@"sns"];
}

- (BOOL)snsIsAnd {
  return ((NSNumber *)self.rawPrefs[@"snsIsAnd"]).boolValue;
}

- (BOOL)snsRequireANWithOR {
  return ((NSNumber *)self.rawPrefs[@"snsRequireANWithOR"]).boolValue;
}

- (NSInteger)whenToPush {
  return ((NSNumber *)self.rawPrefs[@"whenToPush"]).intValue;
}

- (NSInteger)whatNetwork {
  return ((NSNumber *)self.rawPrefs[@"whatNetwork"]).intValue;
}

- (NSDictionary *)customApps {
  return self.rawPrefs[@"customApps"];
}

- (NSPushServiceConfig *)effectiveConfigForAppID:(NSString *)appID {
  NSDictionary *customApp = self.customApps[appID];
  if (!customApp) {
    return self;
  }
  NSMutableDictionary *merged = [self.rawPrefs mutableCopy];
  for (NSString *key in customApp) {
    merged[key] = customApp[key];
  }
  return [NSPushServiceConfig configWithName:self.name
                                    rawPrefs:merged
                             isCustomService:self.isCustomService];
}

@end
