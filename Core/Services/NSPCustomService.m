#import "NSPCustomService.h"
#import "../NSPushConfig.h"
#import "../NSPushSupport.h"

@implementation NSPCustomService

+ (NSString*)serviceName {
  // custom services are keyed by config.name in NSPushServiceManager
  return nil;
}

+ (NSPushRequest*)requestForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  NSMutableDictionary* infoDict =
      [[self baseInfoDictForBulletinContext:context config:config] mutableCopy];

  NSNumber* authMethod = config.rawPrefs[@"authenticationMethod"];
  // authMethod 2 = body auth: embed key inside the JSON payload instead.
  if (authMethod && authMethod.intValue == 2) {
    NSString* paramName = config.rawPrefs[@"paramName"];
    if (paramName && paramName.length > 0) {
      infoDict[paramName] = config.rawPrefs[@"key"] ?: @"";
    } else {
      infoDict[@"key"] = config.rawPrefs[@"key"] ?: @"";
    }
  }

  NSDictionary* headers = @{};
  // authMethod 1 = header auth: send key as a custom HTTP header.
  if (authMethod && authMethod.intValue == 1) {
    NSString* paramName = config.rawPrefs[@"paramName"];
    headers = @{
      (paramName && paramName.length > 0) ? paramName : @"Access-Token"
          : config.rawPrefs[@"key"] ?: @""
    };
  }

  return [NSPushRequest requestWithURLString:[self replacedKeyURLStringForConfig:config]
                                     headers:headers
                                    infoDict:infoDict];
}

+ (BOOL)shouldIncludeIconForConfig:(NSPushServiceConfig*)config {
  NSNumber* includeIcon = config.rawPrefs[@"includeIcon"];
  return includeIcon && includeIcon.boolValue;
}

+ (BOOL)shouldIncludeImageForConfig:(NSPushServiceConfig*)config {
  NSNumber* includeImage = config.rawPrefs[@"includeImage"];
  return includeImage && includeImage.boolValue;
}

@end
