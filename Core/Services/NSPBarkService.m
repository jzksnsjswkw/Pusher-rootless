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

+ (NSPushRequest*)requestForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  return [NSPushRequest requestWithURLString:[self replacedKeyURLStringForConfig:config]
                                     headers:nil
                                    infoDict:@{
                                      @"title" : context.title ?: @"",
                                      @"body" : context.message ?: @""
                                    }];
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
    @"serverURL" : XStrDefault(servicePrefs[NSPPreferenceServiceServerURLKey],
                               @"https://api.day.app")
  };
}

@end
