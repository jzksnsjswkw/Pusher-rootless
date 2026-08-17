#import "NSPSharedSpecifiers.h"

// Per-service specifier builders. Declared in a category header instead of the
// primary NSPSharedSpecifiers interface so the primary implementation is not
// required to implement them in the main compilation unit. Import this header
// (or NSPSharedSpecifiers.h plus this) anywhere the builder selectors are used.

@interface NSPSharedSpecifiers (ServiceBuilders)
+ (NSArray*)getCustomShared:(NSString*)service withAppID:(NSString*)appID;
+ (NSArray*)getCustomShared:(NSString*)service;
+ (NSArray*)pushover:(NSString*)appID;
+ (NSArray*)pushbullet:(NSString*)appID;
+ (NSArray*)ifttt:(NSString*)appID;
+ (NSArray*)pusherReceiver:(NSString*)appID;
+ (NSArray*)wechat:(NSString*)appID;
+ (NSArray*)bark:(NSString*)appID;
@end
