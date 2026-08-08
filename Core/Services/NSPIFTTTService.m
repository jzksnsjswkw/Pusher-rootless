#import "NSPIFTTTService.h"
#import "../NSPBulletinContext.h"
#import "../NSPushServiceConfig.h"

@implementation NSPIFTTTService

+ (NSString*)serviceName {
  return PUSHER_SERVICE_IFTTT;
}

+ (BOOL)shouldIncludeIconForConfig:(NSPushServiceConfig*)config {
  NSNumber* includeIcon = config.rawPrefs[@"includeIcon"];
  return includeIcon && includeIcon.boolValue;
}

+ (NSDictionary*)infoDictForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  NSDictionary* data = [self baseInfoDictForBulletinContext:context
                                                     config:config];

  NSNumber* curateData = config.rawPrefs[@"curateData"];
  if (curateData && curateData.boolValue) {
    NSString* dateStr = [self dateStringForDate:context.bulletin.date
                                         config:config];
    return @{
      @"value1" : context.title ?: @"",
      @"value2" : context.message ?: @"",
      @"value3" : data[@"icon"] ?: dateStr
    };
  }

  id json = data;
  NSData* jsonData = [NSJSONSerialization dataWithJSONObject:json
                                                     options:0
                                                       error:nil];
  if (jsonData) {
    json = [[NSString alloc] initWithData:jsonData
                                 encoding:NSUTF8StringEncoding];
  }
  return @{@"value1" : json};
}

@end
