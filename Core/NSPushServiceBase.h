#import "../global.h"
#import "NSPushService.h"
#import <Foundation/Foundation.h>

// NSPushServiceBase interface is declared in NSPushService.h; this header
// is the single import point for base-class consumers.

@interface NSPushServiceBase (Shared)

+ (NSString*)dateStringForDate:(NSDate*)date
                        config:(NSPushServiceConfig*)config;

@end
