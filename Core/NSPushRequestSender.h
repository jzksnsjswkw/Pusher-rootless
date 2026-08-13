#import "../global.h"
#import <BulletinBoard/BBBulletin.h>
#import <Foundation/Foundation.h>

@class NSPBulletinContext;

@interface NSPushRequestSender : NSObject

+ (instancetype)sharedInstance;

- (void)sendRequestWithURLString:(NSString*)urlString
                        infoDict:(NSDictionary*)infoDict
                         headers:(NSDictionary*)headers
                          method:(NSString*)method
                       logString:(NSString*)logString
                         service:(NSString*)service
                        bulletin:(BBBulletin*)bulletin;

@end
