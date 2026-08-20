#import "NSPSharedSpecifiers.h"

// Shared specifiers for custom services. Built-in services self-register
// their own specifier builders in dedicated NSPSharedSpecifiers+<Service>.m
// files (see NSPushServicePrefs.h), so nothing needs to be declared here
// for them.

@interface NSPSharedSpecifiers (ServiceBuilders)
+ (NSArray*)getCustomShared:(NSString*)service withAppID:(NSString*)appID;
+ (NSArray*)getCustomShared:(NSString*)service;
@end