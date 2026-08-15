#import "NSPPushbulletService.h"
#import "../../helpers.h"
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

+ (NSPushRequest*)requestForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  NSMutableArray* deviceIDs = [NSMutableArray new];
  for (NSDictionary* device in config.rawPrefs[@"devices"] ?: @[]) {
    // Skip malformed entries so a missing "id" can't crash SpringBoard.
    if (![device isKindOfClass:NSDictionary.class] || !device[@"id"]) {
      continue;
    }
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

  return [NSPushRequest requestWithURLString:[self replacedKeyURLStringForConfig:config]
                                     headers:@{@"Access-Token" : XStrDefault(config.rawPrefs[@"token"], @"")}
                                    infoDict:infoDict];
}

@end
