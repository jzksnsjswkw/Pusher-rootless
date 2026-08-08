#import "NSPBarkService.h"
#import "../NSPushServiceConfig.h"
#import "../NSPBulletinContext.h"

@implementation NSPBarkService

+ (NSString *)serviceName {
  return PUSHER_SERVICE_BARK;
}

+ (NSString *)URLStringForConfig:(NSPushServiceConfig *)config {
  NSString *serverURL = config.rawPrefs[@"serverURL"];
  if (serverURL && serverURL.length > 0) {
    if ([serverURL hasSuffix:@"/"]) {
      return [serverURL stringByAppendingString:@"REPLACE_KEY"];
    }
    return [serverURL stringByAppendingFormat:@"/REPLACE_KEY"];
  }
  return PUSHER_SERVICE_BARK_URL;
}

+ (NSDictionary *)infoDictForBulletinContext:(NSPBulletinContext *)context
                                      config:(NSPushServiceConfig *)config {
  return @{
    @"title" : context.title ?: @"",
    @"body" : context.message ?: @""
  };
}

@end
