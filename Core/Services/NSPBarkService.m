#import "NSPBarkService.h"
#import "../../helpers.h"
#import "../NSPushConfig.h"
#import "../NSPushSupport.h"

@implementation NSPBarkService

+ (void)load {
  [NSPushServiceManager registerServiceClass:self forName:[self serviceName]];
}

+ (NSString*)serviceName {
  return PUSHER_SERVICE_BARK;
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
  NSString* finalURL = nil;
  if (serverURL && serverURL.length > 0) {
    if ([serverURL hasSuffix:@"/"]) {
      finalURL = [serverURL stringByAppendingString:@"REPLACE_KEY"];
    } else {
      finalURL = [serverURL stringByAppendingFormat:@"/REPLACE_KEY"];
    }
  } else {
    finalURL = PUSHER_SERVICE_BARK_URL;
  }
  return finalURL;
}

+ (NSDictionary*)extraPrefsForName:(NSString*)name
                      servicePrefs:(NSDictionary*)servicePrefs {
  return @{
    @"serverURL" : servicePrefs[NSPPreferenceServiceServerURLKey]
        ?: @"https://api.day.app"
  };
}

+ (NSDictionary*)infoDictForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  return @{@"title" : context.title ?: @"", @"body" : context.message ?: @""};
}

@end
