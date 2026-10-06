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
  NSString* message = nil;
  if (context.appName) {
    message = context.appName;
  }
  if (context.title) {
    if (message) {
      message = XStr(@"%@: %@", message, context.title);
    } else {
      message = context.title;
    }
  }
  if (context.subtitle) {
    if (message) {
      message = XStr(@"%@\r\n%@", message, context.subtitle);
    } else {
      message = context.subtitle;
    }
  }
  if (context.message) {
    if (message) {
      message = XStr(@"%@\r\n%@", message, context.message);
    } else {
      message = context.message;
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
