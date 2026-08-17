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

+ (NSString*)urlForEventName:(NSString*)eventName
                      dbName:(NSString*)dbName
                   serverURL:(NSString*)serverURL {
  return PUSHER_SERVICE_FEISHU_URL;
}

+ (NSPushRequest*)requestForBulletinContext:(NSPBulletinContext*)context
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

  NSDictionary* infoDict = @{
    @"msg_type" : @"text",
    @"content" : @{@"text" : message ?: @""}
  };
  NSPushRequest* request =
      [NSPushRequest requestWithURLString:[self replacedKeyURLStringForConfig:config]
                                 headers:nil
                                infoDict:infoDict];
  request.logInfoDict = [self logInfoDictForInfoDict:infoDict];
  return request;
}

@end
