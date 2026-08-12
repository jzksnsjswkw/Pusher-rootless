#import "NSPCustomService.h"
#import "../NSPushConfig.h"
#import "../NSPushSupport.h"

@implementation NSPCustomService

+ (NSString*)serviceName {
  // custom services are keyed by config.name in NSPushServiceManager
  return nil;
}

+ (NSString*)URLStringForConfig:(NSPushServiceConfig*)config {
  NSString* key = config.rawPrefs[@"key"];
  NSString* url = config.rawPrefs[@"url"] ?: @"";
  return [url stringByReplacingOccurrencesOfString:@"REPLACE_KEY"
                                         withString:key ?: @""];
}

+ (NSDictionary*)headersForConfig:(NSPushServiceConfig*)config {
  NSNumber* authMethod = config.rawPrefs[@"authenticationMethod"];
  if (authMethod && authMethod.intValue == 1) {
    NSString* paramName = config.rawPrefs[@"paramName"];
    return @{
      (paramName && paramName.length > 0) ? paramName : @"Access-Token"
          : config.rawPrefs[@"key"] ?: @""
    };
  }
  return @{};
}

+ (BOOL)shouldIncludeIconForConfig:(NSPushServiceConfig*)config {
  NSNumber* includeIcon = config.rawPrefs[@"includeIcon"];
  return includeIcon && includeIcon.boolValue;
}

+ (BOOL)shouldIncludeImageForConfig:(NSPushServiceConfig*)config {
  NSNumber* includeImage = config.rawPrefs[@"includeImage"];
  return includeImage && includeImage.boolValue;
}

+ (NSDictionary*)infoDictForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  NSMutableDictionary* data =
      [[super infoDictForBulletinContext:context config:config] mutableCopy];

  NSNumber* authMethod = config.rawPrefs[@"authenticationMethod"];
  if (authMethod && authMethod.intValue == 2) {
    NSString* paramName = config.rawPrefs[@"paramName"];
    if (paramName && paramName.length > 0) {
      data[paramName] = config.rawPrefs[@"key"] ?: @"";
    } else {
      data[@"key"] = config.rawPrefs[@"key"] ?: @"";
    }
  }
  return data;
}

@end
