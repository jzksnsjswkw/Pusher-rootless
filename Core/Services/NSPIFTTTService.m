#import "NSPIFTTTService.h"
#import "../../helpers.h"
#import "../NSPushConfig.h"
#import "../NSPushSupport.h"

// Guarded prefs bool accessor: prefs can be hand-edited to non-NSNumber
// values; only NSNumber/NSString implement boolValue safely.
static BOOL NSPIFTTTBool(id value) {
  if ([value isKindOfClass:NSNumber.class] ||
      [value isKindOfClass:NSString.class]) {
    return [value boolValue];
  }
  return NO;
}

@implementation NSPIFTTTService

+ (void)load {
  [NSPushServiceManager registerServiceClass:self forName:[self serviceName]];
}

+ (NSString*)serviceName {
  return PUSHER_SERVICE_IFTTT;
}

+ (NSString*)urlForEventName:(NSString*)eventName
                      dbName:(NSString*)dbName
                   serverURL:(NSString*)serverURL {
  return [PUSHER_SERVICE_IFTTT_URL
      stringByReplacingOccurrencesOfString:@"REPLACE_EVENT_NAME"
                                withString:XStrDefault(eventName, @"")];
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
  return NSPIFTTTBool(config.rawPrefs[@"includeIcon"]);
}

+ (NSPushRequest*)requestForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  NSDictionary* data = [self baseInfoDictForBulletinContext:context
                                                      config:config];

  // curateData = curated single-field webhook format (value1-3, icon or date
  // as value3); otherwise the whole info dict is JSON-serialized into value1.
  NSDictionary* infoDict;
  if (NSPIFTTTBool(config.rawPrefs[@"curateData"])) {
    NSString* dateStr = [self dateStringForDate:context.bulletin.date
                                         config:config];
    infoDict = @{
      @"value1" : context.title ?: @"",
      @"value2" : context.message ?: @"",
      @"value3" : data[@"icon"] ?: dateStr
    };
  } else {
    id json = data;
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:json
                                                       options:0
                                                         error:nil];
    if (jsonData) {
      json = [[NSString alloc] initWithData:jsonData
                                   encoding:NSUTF8StringEncoding];
    }
    infoDict = @{@"value1" : json};
  }

  return [NSPushRequest requestWithURLString:[self replacedKeyURLStringForConfig:config]
                                     headers:nil
                                    infoDict:infoDict];
}

@end
