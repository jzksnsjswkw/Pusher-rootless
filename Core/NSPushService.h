#import "NSPushConstants.h"
#import <Foundation/Foundation.h>
#import "NSPushConfig.h"
#import "NSPushRequest.h"

@class NSPBulletinContext;

@protocol NSPPushService <NSObject>

// Registry key. Must match the service name used in prefs (e.g. "Pushover").
+ (NSString*)serviceName;

// Bundle ID used for same-app loop prevention. @"" for services that
// don't participate (only Pushover and Pushbullet return their app ID).
+ (NSString*)loopPreventionAppID;

// Final, fully-authorized request (URL + headers + body) for the bulletin
// context. The service composes its own body and applies its own auth here
// (e.g. Pushover merges its token/user credentials into the body, Pushbullet
// puts its token in a header). The base class provides an async default that
// wraps the synchronous requestForBulletinContext:config: below; a service
// overrides the sync method for the standard REPLACE_KEY -> key substitution,
// or overrides this async method directly for behavior that needs more (e.g.
// Wechat's token fetch).
+ (void)requestForBulletinContext:(NSPBulletinContext*)context
                           config:(NSPushServiceConfig*)config
                       completion:(void (^)(NSPushRequest* request))completion;

// Synchronous request builder. The base async default calls this; the base
// implementation raises to enforce that every service overrides it (or
// overrides the async method instead, e.g. Wechat's token fetch). Override it
// to supply the service's request (typically substituting REPLACE_KEY with the
// configured key -- see urlForEventName:dbName:serverURL:).
+ (NSPushRequest*)requestForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config;

// Service-specific normalized prefs keys (beyond the shared template filled
// by NSPushPrefs). `name` is the service name, `servicePrefs` the service's
// nested object dict (BuiltInServices[name]). Base returns @{}.
+ (NSDictionary*)extraPrefsForName:(NSString*)name
                      servicePrefs:(NSDictionary*)servicePrefs;

// Service-specific keys for a single custom-app sub-config. `appPrefs` is
// the raw prefs of one custom app. Base returns @{}.
+ (NSDictionary*)extraCustomAppPrefsForName:(NSString*)name
                                    appPrefs:(NSDictionary*)appPrefs;

// Build the service's request URL from the supplied options. `eventName`
// substitutes REPLACE_EVENT_NAME (IFTTT), `dbName` substitutes REPLACE_DB_NAME
// (Pusher Receiver), and `serverURL` selects a custom endpoint (Bark). The
// returned string may still contain REPLACE_KEY, which
// requestForBulletinContext:config: substitutes with the configured key at
// send time. Base returns @"" (custom / unknown services).
+ (NSString*)urlForEventName:(NSString*)eventName
                      dbName:(NSString*)dbName
                   serverURL:(NSString*)serverURL;

@end

// Base class providing shared defaults and the common data-dict builder
// used by IFTTT / Pusher Receiver / custom services.
@interface NSPushServiceBase : NSObject <NSPPushService>

// Shared helper: substitutes REPLACE_KEY in the configured URL template with
// the configured key. Used by services whose URL follows the standard
// template pattern (Bark, Feishu, IFTTT, Pushbullet, ...).
+ (NSString*)replacedKeyURLStringForConfig:(NSPushServiceConfig*)config;

// Shared data dict: deviceName/appName/appID/title/subtitle/message/date
// + optional icon base64 + optional image (shrunk to max width/height)
// + imageShrinkFactor. Used by services that share the common data dict
// (IFTTT, Pusher Receiver, custom).
+ (NSDictionary*)baseInfoDictForBulletinContext:(NSPBulletinContext*)context
                                         config:(NSPushServiceConfig*)config;

// Whether the service should include the app icon in the shared data dict.
+ (BOOL)shouldIncludeIconForConfig:(NSPushServiceConfig*)config;

// Whether the service should include the bulletin's primary attachment image.
+ (BOOL)shouldIncludeImageForConfig:(NSPushServiceConfig*)config;

@end

@interface NSPushServiceBase (Shared)

+ (NSString*)dateStringForDate:(NSDate*)date
                        config:(NSPushServiceConfig*)config;

@end

@interface NSPushServiceManager : NSObject

+ (void)registerServiceClass:(Class)serviceClass forName:(NSString*)name;
+ (Class)serviceClassForName:(NSString*)name;

@end
