#import "NSPPushbulletService.h"
#import "../NSPushServiceConfig.h"
#import "../NSPBulletinContext.h"

@implementation NSPPushbulletService

+ (NSString *)serviceName {
  return PUSHER_SERVICE_PUSHBULLET;
}

+ (NSString *)loopPreventionAppID {
  return PUSHER_SERVICE_PUSHBULLET_APP_ID;
}

+ (PusherAuthorizationType)authTypeForConfig:(NSPushServiceConfig *)config {
  return PusherAuthorizationTypeHeader;
}

+ (NSDictionary *)credentialsForConfig:(NSPushServiceConfig *)config {
  return @{
    @"headerName" : @"Access-Token",
    @"value" : config.rawPrefs[@"token"] ?: @""
  };
}

+ (NSString *)URLStringForConfig:(NSPushServiceConfig *)config {
  return PUSHER_SERVICE_PUSHBULLET_URL;
}

+ (NSDictionary *)infoDictForBulletinContext:(NSPBulletinContext *)context
                                      config:(NSPushServiceConfig *)config {
  NSMutableArray *deviceIDs = [NSMutableArray new];
  for (NSDictionary *device in config.rawPrefs[@"devices"] ?: @[]) {
    [deviceIDs addObject:device[@"id"]];
  }

  // should always only be one, but just in case
  NSString *firstDevice = [deviceIDs firstObject];
  NSMutableDictionary *infoDict = [@{
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
