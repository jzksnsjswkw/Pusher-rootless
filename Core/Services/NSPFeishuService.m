#import "NSPFeishuService.h"
#import "../../helpers.h"
#import "../NSPBulletinContext.h"

@implementation NSPFeishuService

+ (NSString *)serviceName {
  return PUSHER_SERVICE_FEISHU;
}

+ (NSDictionary *)infoDictForBulletinContext:(NSPBulletinContext *)context
                                      config:(NSPushServiceConfig *)config {
  BBBulletin *bulletin = context.bulletin;

  NSString *message = nil;
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

  return @{
    @"msg_type" : @"text",
    @"content" : @{
      @"text" : message ?: @""
    }
  };
}

@end
