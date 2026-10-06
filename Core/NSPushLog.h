#import <Foundation/Foundation.h>

@class NSPBulletinContext;

// The on-device push log. Keyed by the bulletin identity carried on the
// context (bulletinID + appID + timestamp), so the log layer never has to know
// about BBBulletin.
@interface NSPushLog : NSObject

+ (void)addToLogIfEnabledForService:(NSString*)service
                            context:(NSPBulletinContext*)context
                              label:(NSString*)label
                             object:(id)object;

+ (void)addToLogIfEnabledForService:(NSString*)service
                            context:(NSPBulletinContext*)context
                              label:(NSString*)label
                             object:(id)object
                       dontTruncate:(BOOL)dontTruncate;

+ (NSString*)stringForObject:(id)object;
+ (NSString*)stringForObject:(id)object dontTruncate:(BOOL)dontTruncate;

@end