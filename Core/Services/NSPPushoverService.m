#import "NSPPushoverService.h"
#import "../NSPushConfig.h"
#import "../NSPushSupport.h"

@implementation NSPPushoverService

+ (void)load {
  [NSPushServiceManager registerServiceClass:self forName:[self serviceName]];
}

+ (NSString*)serviceName {
  return PUSHER_SERVICE_PUSHOVER;
}

+ (NSString*)urlForEventName:(NSString*)eventName
                      dbName:(NSString*)dbName
                   serverURL:(NSString*)serverURL {
  return PUSHER_SERVICE_PUSHOVER_URL;
}

+ (NSString*)loopPreventionAppID {
  return PUSHER_SERVICE_PUSHOVER_APP_ID;
}

+ (NSString*)URLStringForConfig:(NSPushServiceConfig*)config {
  NSString* key = config.rawPrefs[@"key"];
  NSString* url = config.rawPrefs[@"url"] ?: @"";
  return [url stringByReplacingOccurrencesOfString:@"REPLACE_KEY"
                                         withString:key ?: @""];
}

+ (NSDictionary*)infoDictForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  NSMutableArray* deviceIDs = [NSMutableArray new];
  for (NSDictionary* device in config.rawPrefs[@"devices"] ?: @[]) {
    // Skip malformed entries so a missing "id" can't crash SpringBoard.
    if (![device isKindOfClass:NSDictionary.class] || !device[@"id"]) {
      continue;
    }
    [deviceIDs addObject:device[@"id"]];
  }

  NSMutableDictionary* infoDict = [@{
    @"token" : config.rawPrefs[@"token"] ?: @"",
    @"user" : config.rawPrefs[@"user"] ?: @"",
    @"title" : context.title ?: @"",
    @"message" : context.message ?: @"",
    @"device" : [deviceIDs componentsJoinedByString:@","]
  } mutableCopy];

  NSString* firstSoundID = [config.rawPrefs[@"sounds"] firstObject];
  if (firstSoundID) {
    infoDict[@"sound"] = firstSoundID;
  }

  return infoDict;
}

@end
