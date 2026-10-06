#import "NSPushConstants.h"
#import <Foundation/Foundation.h>

@class NSPBulletinContext;
@class NSPushRequest;

// Sends a fully-built NSPushRequest (URL/headers/body/method all decided by the
// service) and owns the per-bulletin retry budget. It only needs the
// bulletin's identity for the retry key and the log -- carried by the plain
// NSPBulletinContext value object, so this transport layer does not depend on
// BBBulletin.
@interface NSPushRequestSender : NSObject

+ (instancetype)sharedInstance;

- (void)sendRequest:(NSPushRequest*)request
          logString:(NSString*)logString
            service:(NSString*)service
            context:(NSPBulletinContext*)context;

@end