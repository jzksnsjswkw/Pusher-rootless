#import "../NSPushService.h"
#import <Foundation/Foundation.h>

#define PUSHER_SERVICE_WECHAT @"Wechat"
#define PUSHER_SERVICE_WECHAT_URL                                              \
  @"https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token="            \
  @"REPLACE_DYNAMIC_KEY"

@interface NSPWechatService : NSPushServiceBase
@end
