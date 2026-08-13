#import "NSPIFTTTService.h"
#import "../../helpers.h"
#import "../NSPushConfig.h"
#import "../NSPushSupport.h"

@implementation NSPIFTTTService

+ (void)load {
  [NSPushServiceManager registerServiceClass:self forName:[self serviceName]];
}

+ (NSString*)serviceName {
  return PUSHER_SERVICE_IFTTT;
}

+ (NSString*)URLStringForConfig:(NSPushServiceConfig*)config {
  NSString* key = config.rawPrefs[@"key"];
  NSString* url = config.rawPrefs[@"url"] ?: @"";
  return [url stringByReplacingOccurrencesOfString:@"REPLACE_KEY"
                                         withString:key ?: @""];
}

+ (NSString*)urlForEventName:(NSString*)eventName
                      dbName:(NSString*)dbName
                   serverURL:(NSString*)serverURL {
  return [PUSHER_SERVICE_IFTTT_URL
      stringByReplacingOccurrencesOfString:@"REPLACE_EVENT_NAME"
                                withString:eventName ?: @""];
}

+ (NSDictionary*)extraPrefsForName:(NSString*)name
                      servicePrefs:(NSDictionary*)servicePrefs {
  return @{
    @"includeIcon" : servicePrefs[NSPPreferenceServiceIncludeIconKey] ?: @NO,
    @"curateData" : servicePrefs[NSPPreferenceServiceCurateDataKey] ?: @YES
  };
}

+ (NSDictionary*)extraCustomAppPrefsForName:(NSString*)name
                                   appPrefs:(NSDictionary*)appPrefs {
  return @{
    @"includeIcon" : appPrefs[@"includeIcon"] ?: @NO,
    @"curateData" : appPrefs[@"curateData"] ?: @YES
  };
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
  // curateData = curated single-field webhook format (value1-3, icon or date
  // as value3); otherwise the whole info dict is JSON-serialized into value1.
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
