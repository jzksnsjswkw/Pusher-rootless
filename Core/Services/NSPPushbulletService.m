#import "NSPPushbulletService.h"
#import "../NSPushConfig.h"
#import "../NSPushSupport.h"

@implementation NSPPushbulletService

+ (void)load {
  [NSPushServiceManager registerServiceClass:self forName:[self serviceName]];
}

+ (NSString*)serviceName {
  return PUSHER_SERVICE_PUSHBULLET;
}

+ (NSString*)urlForEventName:(NSString*)eventName
                      dbName:(NSString*)dbName
                   serverURL:(NSString*)serverURL {
  return PUSHER_SERVICE_PUSHBULLET_URL;
}

+ (NSString*)loopPreventionAppID {
  return PUSHER_SERVICE_PUSHBULLET_APP_ID;
}

+ (NSDictionary*)headersForConfig:(NSPushServiceConfig*)config {
  return @{@"Access-Token" : config.rawPrefs[@"token"] ?: @""};
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
    [deviceIDs addObject:device[@"id"]];
  }

  // should always only be one, but just in case
  NSString* firstDevice = [deviceIDs firstObject];
  NSMutableDictionary* infoDict = [@{
    @"type" : @"note",
    @"title" : context.title ?: @"",
    @"body" : context.message ?: @""
  } mutableCopy];
  if (firstDevice) {
    infoDict[@"device_iden"] = firstDevice;
  }

  return infoDict;
}

@end
