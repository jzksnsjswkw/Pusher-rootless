#import "NSPCustomService.h"
#import "../NSPushServiceConfig.h"

@implementation NSPCustomService

+ (NSString*)serviceName {
  // custom services are keyed by config.name in NSPushServiceManager
  return nil;
}

+ (PusherAuthorizationType)authTypeForConfig:(NSPushServiceConfig*)config {
  NSNumber* authMethod = config.rawPrefs[@"authenticationMethod"];
  if (!authMethod) {
    return PusherAuthorizationTypeNone;
  }
  switch (authMethod.intValue) {
  case 1:
    return PusherAuthorizationTypeHeader;
  case 2:
    return PusherAuthorizationTypeCredentials;
  default:
    return PusherAuthorizationTypeNone;
  }
}

+ (NSDictionary*)credentialsForConfig:(NSPushServiceConfig*)config {
  PusherAuthorizationType authType = [self authTypeForConfig:config];
  if (authType == PusherAuthorizationTypeCredentials) {
    NSString* paramName = config.rawPrefs[@"paramName"];
    if (paramName && paramName.length > 0) {
      return @{paramName : config.rawPrefs[@"key"] ?: @""};
    }
    return @{@"key" : config.rawPrefs[@"key"] ?: @""};
  }
  if (authType == PusherAuthorizationTypeHeader) {
    NSString* paramName = config.rawPrefs[@"paramName"];
    return @{
      @"headerName" : (paramName && paramName.length > 0) ? paramName
                                                          : @"Access-Token",
      @"value" : config.rawPrefs[@"key"] ?: @""
    };
  }
  return @{@"key" : config.rawPrefs[@"key"] ?: @""};
}

@end
