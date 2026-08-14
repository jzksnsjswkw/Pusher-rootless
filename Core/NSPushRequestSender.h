#import "NSPushConstants.h"
#import <BulletinBoard/BBBulletin.h>
#import <Foundation/Foundation.h>

@class NSPushRequest;

@interface NSPushRequestSender : NSObject

+ (instancetype)sharedInstance;

- (void)sendRequest:(NSPushRequest*)request
          logString:(NSString*)logString
            service:(NSString*)service
           bulletin:(BBBulletin*)bulletin;

@end
