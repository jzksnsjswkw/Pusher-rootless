#import "NSPPusherReceiverService.h"
#import "../NSPushServiceConfig.h"
#import "../NSPBulletinContext.h"

@implementation NSPPusherReceiverService

+ (NSString *)serviceName {
  return PUSHER_SERVICE_PUSHER_RECEIVER;
}

+ (PusherAuthorizationType)authTypeForConfig:(NSPushServiceConfig *)config {
  return PusherAuthorizationTypeHeader;
}

+ (NSDictionary *)credentialsForConfig:(NSPushServiceConfig *)config {
  return @{
    @"headerName" : @"x-apikey",
    @"value" : config.rawPrefs[@"key"] ?: @""
  };
}

+ (BOOL)shouldIncludeIconForConfig:(NSPushServiceConfig *)config {
  NSNumber *includeIcon = config.rawPrefs[@"includeIcon"];
  return includeIcon && includeIcon.boolValue;
}

+ (BOOL)shouldIncludeImageForConfig:(NSPushServiceConfig *)config {
  NSNumber *includeImage = config.rawPrefs[@"includeImage"];
  return includeImage && includeImage.boolValue;
}

@end
