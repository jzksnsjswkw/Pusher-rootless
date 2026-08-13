#import "NSPPushoverService.h"
#import "../NSPBulletinContext.h"
#import "../NSPushServiceConfig.h"

@implementation NSPPushoverService

+ (NSString*)serviceName {
  return PUSHER_SERVICE_PUSHOVER;
}

+ (NSString*)loopPreventionAppID {
  return PUSHER_SERVICE_PUSHOVER_APP_ID;
}

+ (PusherAuthorizationType)authTypeForConfig:(NSPushServiceConfig*)config {
  return PusherAuthorizationTypeCredentials;
}

+ (NSDictionary*)credentialsForConfig:(NSPushServiceConfig*)config {
  return @{
    @"token" : config.rawPrefs[@"token"] ?: @"",
    @"user" : config.rawPrefs[@"user"] ?: @""
  };
}

+ (NSString*)URLStringForConfig:(NSPushServiceConfig*)config {
  return PUSHER_SERVICE_PUSHOVER_URL;
}

+ (NSDictionary*)infoDictForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  NSMutableArray* deviceIDs = [NSMutableArray new];
  for (NSDictionary* device in config.rawPrefs[@"devices"] ?: @[]) {
    [deviceIDs addObject:device[@"id"]];
  }

  NSMutableDictionary* infoDict = [@{
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
