#import "../NSPushService.h"
#import <Foundation/Foundation.h>

#define PUSHER_SERVICE_FEISHU @"Feishu"
#define PUSHER_SERVICE_FEISHU_URL                                              \
  @"https://open.feishu.cn/open-apis/bot/v2/hook/REPLACE_KEY"

@interface NSPFeishuService : NSPushServiceBase
@end
