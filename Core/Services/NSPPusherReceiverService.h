#import "../NSPushService.h"
#import <Foundation/Foundation.h>

#define PUSHER_SERVICE_PUSHER_RECEIVER @"Pusher Receiver"
#define PUSHER_SERVICE_PUSHER_RECEIVER_URL                                     \
  @"https://REPLACE_DB_NAME.restdb.io/rest/notifications"

@interface NSPPusherReceiverService : NSPushServiceBase
@end
