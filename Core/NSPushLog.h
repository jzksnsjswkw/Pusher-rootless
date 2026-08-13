#import <BulletinBoard/BBBulletin.h>
#import <Foundation/Foundation.h>

@interface NSPushLog : NSObject

+ (void)addToLogIfEnabledForService:(NSString*)service
                           bulletin:(BBBulletin*)bulletin
                              label:(NSString*)label
                             object:(id)object;

+ (void)addToLogIfEnabledForService:(NSString*)service
                           bulletin:(BBBulletin*)bulletin
                              label:(NSString*)label
                             object:(id)object
                       dontTruncate:(BOOL)dontTruncate;

+ (NSString*)stringForObject:(id)object;
+ (NSString*)stringForObject:(id)object dontTruncate:(BOOL)dontTruncate;

@end
