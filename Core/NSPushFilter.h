#import <Foundation/Foundation.h>

@class NSPBulletinContext;
@class NSPDeviceState;
@class NSPushConfigSnapshot;
@class NSPushNotificationSettings;
@class NSPushServiceConfig;

// The pre-flight filters. Every input is a plain value object (see
// NSPushSupport.h) or a config snapshot, so these are pure decisions the
// SpringBoard hook layer can call and, unlike before, nothing here reaches
// into BBServer / BBSectionInfo / SBLockScreenManager / SBWiFiManager.
@interface NSPushFilter : NSObject

// Global pre-flight for one bulletin: pusher enabled, the test-result banner,
// the global app list, whether SpringBoard could supply this app's settings at
// all, and whether every enabled service has a config.
+ (NSString*)globalReasonIfAnyWithContext:(NSPBulletinContext*)context
                                   config:(NSPushConfigSnapshot*)config;

+ (NSString*)appListReasonIfAnyWithConfig:(NSPushServiceConfig*)config
                                    appID:(NSString*)appID;

+ (NSString*)snsReasonIfAnyWithSNS:(NSArray*)sns
                          settings:(NSPushNotificationSettings*)settings
                             isAnd:(BOOL)isAnd
                   requireANWithOR:(BOOL)requireANWithOR;

+ (NSString*)deviceReasonIfAnyWithWhenToPush:(int)whenToPush
                                 whatNetwork:(int)whatNetwork
                                 deviceState:(NSPDeviceState*)deviceState;

@end