#import "../global.h"
#import <Foundation/Foundation.h>
#import "NSPushConfig.h"

@class NSPBulletinContext;

@protocol NSPPushService <NSObject>

// Registry key. Must match the service name used in prefs (e.g. "Pushover").
+ (NSString*)serviceName;

// Bundle ID used for same-app loop prevention. @"" for services that
// don't participate (only Pushover and Pushbullet return their app ID).
+ (NSString*)loopPreventionAppID;

// Request body dictionary (service-specific composition). The service is
// responsible for applying its own auth here (e.g. Pushover merges its
// token/user credentials into the body).
+ (NSDictionary*)infoDictForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config;

// Final, fully-authorized request URL. The base class provides an async
// default that wraps the synchronous URLStringForConfig: below; a service
// overrides the sync method for the standard REPLACE_KEY -> key substitution,
// or overrides this async method directly for behavior that needs more (e.g.
// Wechat's token fetch).
+ (void)URLStringForConfig:(NSPushServiceConfig*)config
                completion:(void (^)(NSString* urlString))completion;

// Synchronous URL builder. The base async default calls this; the base
// implementation raises to enforce that every service overrides it (or
// overrides the async method instead, e.g. Wechat's token fetch). Override it
// to supply the service's URL (typically substituting REPLACE_KEY with the
// configured key -- see urlForEventName:dbName:serverURL:).
+ (NSString*)URLStringForConfig:(NSPushServiceConfig*)config;

// HTTP headers carrying the service's auth (e.g. Pushbullet's Access-Token
// or Pusher Receiver's x-apikey). Default: none.
+ (NSDictionary*)headersForConfig:(NSPushServiceConfig*)config;

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
// returned string may still contain REPLACE_KEY, which URLStringForConfig:
// substitutes with the configured key at send time. Base returns @"" (custom /
// unknown services).
+ (NSString*)urlForEventName:(NSString*)eventName
                      dbName:(NSString*)dbName
                   serverURL:(NSString*)serverURL;

@end

// Base class providing shared defaults and the common data-dict builder
// used by IFTTT / Pusher Receiver / custom services.
@interface NSPushServiceBase : NSObject <NSPPushService>

// Shared data dict: deviceName/appName/appID/title/subtitle/message/date
// + optional icon base64 + optional image (shrunk to max width/height)
// + imageShrinkFactor. Used by the base infoDict implementation.
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
+ (NSArray*)builtinServiceNames;

@end
