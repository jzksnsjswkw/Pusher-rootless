#import <Foundation/Foundation.h>

// Per-service shared-specifier builders. Mirrors the Core-side service
// registration (NSPushServiceManager): each built-in service's Preferences UI
// self-registers a builder block in +load, so NSPSharedSpecifiers can look
// builders up by service name instead of a hand-maintained dispatch chain.
// Adding a built-in service with extra shared specifiers requires only a new
// file that registers itself -- no edits to shared code.

// Builds the shared specifiers appended to a service's settings page.
// `appID` is non-nil when the page is a per-app override (custom app);
// nil for the service's main settings page.
typedef NSArray* (^NSPSharedSpecifierBuilder)(NSString* appID);

@interface NSPushServicePrefsManager : NSObject

+ (void)registerBuilder:(NSPSharedSpecifierBuilder)builder
             forService:(NSString*)service;

+ (NSPSharedSpecifierBuilder)builderForService:(NSString*)service;

@end