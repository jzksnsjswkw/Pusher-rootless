#import "../NSPushService.h"
#import <Foundation/Foundation.h>

#define PUSHER_SERVICE_IFTTT @"IFTTT"
#define PUSHER_SERVICE_IFTTT_URL                                               \
  @"https://maker.ifttt.com/trigger/REPLACE_EVENT_NAME/with/key/REPLACE_KEY"

@interface NSPIFTTTService : NSPushServiceBase
@end
