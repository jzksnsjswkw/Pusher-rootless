#import "NSPFeishuService.h"
#import "../../helpers.h"
#import "../NSPushSupport.h"

@implementation NSPFeishuService

+ (void)load {
  [NSPushServiceManager registerServiceClass:self forName:[self serviceName]];
}

+ (NSString*)serviceName {
  return PUSHER_SERVICE_FEISHU;
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
  return PUSHER_SERVICE_FEISHU_URL;
}

+ (NSDictionary*)infoDictForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  BBBulletin* bulletin = context.bulletin;

  NSString* message = nil;
  if (context.appName) {
    message = context.appName;
  }
  if (bulletin.title) {
    if (message) {
      message = XStr(@"%@: %@", message, bulletin.title);
    } else {
      message = bulletin.title;
    }
  }
  if (bulletin.subtitle) {
    if (message) {
      message = XStr(@"%@\r\n%@", message, bulletin.subtitle);
    } else {
      message = bulletin.subtitle;
    }
  }
  if (bulletin.message) {
    if (message) {
      message = XStr(@"%@\r\n%@", message, bulletin.message);
    } else {
      message = bulletin.message;
    }
  }

  return @{@"msg_type" : @"text", @"content" : @{@"text" : message ?: @""}};
}

@end
