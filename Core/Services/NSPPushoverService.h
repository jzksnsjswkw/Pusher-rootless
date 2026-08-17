#import "../NSPushService.h"
#import <Foundation/Foundation.h>

#define PUSHER_SERVICE_PUSHOVER @"Pushover"
#define PUSHER_SERVICE_PUSHOVER_URL @"https://api.pushover.net/1/messages.json"

@interface NSPPushoverService : NSPushServiceBase
@end
