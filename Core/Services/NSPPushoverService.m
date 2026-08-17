#import "NSPPushoverService.h"
#import "../../helpers.h"
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

  NSMutableDictionary* infoDict = [@{
    @"token" : XStrDefault(config.rawPrefs[@"token"], @""),
    @"user" : XStrDefault(config.rawPrefs[@"user"], @""),
    @"title" : context.title ?: @"",
    @"message" : context.message ?: @"",
    @"device" : [deviceIDs componentsJoinedByString:@","]
  } mutableCopy];

  NSString* firstSoundID = [config.rawPrefs[@"sounds"] firstObject];
  if (firstSoundID) {
    infoDict[@"sound"] = firstSoundID;
  }

  NSPushRequest* request =
      [NSPushRequest requestWithURLString:[self replacedKeyURLStringForConfig:config]
                                 headers:nil
                                infoDict:infoDict];
  request.logInfoDict = [self logInfoDictForInfoDict:infoDict];
  return request;
}

@end
