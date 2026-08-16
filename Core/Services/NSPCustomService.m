#import "NSPCustomService.h"
#import "../../helpers.h"
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

  NSInteger authMethod = NSPushIntegerValue(config.rawPrefs[@"authenticationMethod"], 0);
  // authMethod 2 = body auth: embed key inside the JSON payload instead.
  if (authMethod == 2) {
    NSString* paramName = XStrDefault(config.rawPrefs[@"paramName"], @"");
    if (paramName.length > 0) {
      infoDict[paramName] = XStrDefault(config.rawPrefs[@"key"], @"");
    } else {
      infoDict[@"key"] = XStrDefault(config.rawPrefs[@"key"], @"");
    }
  }

  NSDictionary* headers = @{};
  // authMethod 1 = header auth: send key as a custom HTTP header.
  if (authMethod == 1) {
    NSString* paramName = XStrDefault(config.rawPrefs[@"paramName"], @"");
    headers = @{
      (paramName.length > 0) ? paramName : @"Access-Token"
          : XStrDefault(config.rawPrefs[@"key"], @"")
    };
  }

  return [NSPushRequest requestWithURLString:[self replacedKeyURLStringForConfig:config]
                                     headers:headers
                                    infoDict:infoDict];
}

+ (BOOL)shouldIncludeIconForConfig:(NSPushServiceConfig*)config {
  return NSPushBoolValue(config.rawPrefs[@"includeIcon"]);
}

+ (BOOL)shouldIncludeImageForConfig:(NSPushServiceConfig*)config {
  return NSPushBoolValue(config.rawPrefs[@"includeImage"]);
}

@end
