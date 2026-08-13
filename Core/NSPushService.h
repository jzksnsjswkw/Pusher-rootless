#import <Foundation/Foundation.h>
#import "../global.h"

@class NSPBulletinContext;
@class NSPushServiceConfig;

@protocol NSPPushService <NSObject>

// Registry key. Must match the service name used in prefs (e.g. "Pushover").
+ (NSString *)serviceName;

// Bundle ID used for same-app loop prevention. @"" for services that
// don't participate (only Pushover and Pushbullet return their app ID).
+ (NSString *)loopPreventionAppID;

// Authorization type for the service. Drives how credentials are applied
// (body merge / URL replacement / request header).
+ (PusherAuthorizationType)authTypeForConfig:(NSPushServiceConfig *)config;

// Credentials dictionary. Shapes:
//   {token, user}                          - Credentials auth
//   {headerName, value}                    - Header auth
//   {key}                                  - ReplaceKey auth (default)
//   {paramName: value}                     - custom services with paramName
+ (NSDictionary *)credentialsForConfig:(NSPushServiceConfig *)config;

// Request URL template. May contain REPLACE_KEY / REPLACE_DYNAMIC_KEY
// placeholders - the request sender substitutes them at send time.
+ (NSString *)URLStringForConfig:(NSPushServiceConfig *)config;

// Request body dictionary (service-specific composition).
+ (NSDictionary *)infoDictForBulletinContext:(NSPBulletinContext *)context
                                      config:(NSPushServiceConfig *)config;

@optional

// Fetch an auth token that must be substituted for REPLACE_DYNAMIC_KEY
// (Wechat only). Default implementation invokes completion with @"".
+ (void)fetchDynamicKeyForConfig:(NSPushServiceConfig *)config
                      completion:(void (^)(NSString *key))completion;

@end

// Base class providing shared defaults and the common data-dict builder
// used by IFTTT / Pusher Receiver / custom services.
@interface NSPushServiceBase : NSObject <NSPPushService>

// Shared data dict: deviceName/appName/appID/title/subtitle/message/date
// + optional icon base64 + optional image (shrunk to max width/height)
// + imageShrinkFactor. Used by the base infoDict implementation.
+ (NSDictionary *)baseInfoDictForBulletinContext:(NSPBulletinContext *)context
                                          config:(NSPushServiceConfig *)config;

// Whether the service should include the app icon in the shared data dict.
+ (BOOL)shouldIncludeIconForConfig:(NSPushServiceConfig *)config;

// Whether the service should include the bulletin's primary attachment image.
+ (BOOL)shouldIncludeImageForConfig:(NSPushServiceConfig *)config;

@end
