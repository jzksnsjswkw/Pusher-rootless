#import "NSPPusherReceiverService.h"
#import "../../helpers.h"
#import "../NSPushConfig.h"
#import "../NSPushSupport.h"

// Guarded prefs bool accessor: prefs can be hand-edited to non-NSNumber
// values; only NSNumber/NSString implement boolValue safely.
static BOOL NSPReceiverBool(id value) {
  if ([value isKindOfClass:NSNumber.class] ||
      [value isKindOfClass:NSString.class]) {
    return [value boolValue];
  }
  return NO;
}

@implementation NSPPusherReceiverService

+ (void)load {
  [NSPushServiceManager registerServiceClass:self forName:[self serviceName]];
}

+ (NSString*)serviceName {
  return PUSHER_SERVICE_PUSHER_RECEIVER;
}

+ (NSPushRequest*)requestForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  return [NSPushRequest
      requestWithURLString:[self replacedKeyURLStringForConfig:config]
                   headers:@{@"x-apikey" : XStrDefault(config.rawPrefs[@"key"], @"")}
                  infoDict:[self baseInfoDictForBulletinContext:context
                                                         config:config]];
}

+ (NSString*)urlForEventName:(NSString*)eventName
                      dbName:(NSString*)dbName
                   serverURL:(NSString*)serverURL {
  return [PUSHER_SERVICE_PUSHER_RECEIVER_URL
      stringByReplacingOccurrencesOfString:@"REPLACE_DB_NAME"
                                withString:XStrDefault(dbName, @"")];
}

+ (NSDictionary*)extraPrefsForName:(NSString*)name
                      servicePrefs:(NSDictionary*)servicePrefs {
  return @{
    @"includeIcon" : servicePrefs[NSPPreferenceServiceIncludeIconKey] ?: @YES,
    @"includeImage" : servicePrefs[NSPPreferenceServiceIncludeImageKey] ?: @YES,
    @"imageMaxWidth" : servicePrefs[NSPPreferenceServiceImageMaxWidthKey]
        ?: @(PUSHER_DEFAULT_MAX_WIDTH),
    @"imageMaxHeight" : servicePrefs[NSPPreferenceServiceImageMaxHeightKey]
        ?: @(PUSHER_DEFAULT_MAX_HEIGHT),
    @"imageShrinkFactor" :
            servicePrefs[NSPPreferenceServiceImageShrinkFactorKey]
        ?: @(PUSHER_DEFAULT_SHRINK_FACTOR)
  };
}

+ (NSDictionary*)extraCustomAppPrefsForName:(NSString*)name
                                   appPrefs:(NSDictionary*)appPrefs {
  return @{
    @"includeIcon" : appPrefs[@"includeIcon"] ?: @YES,
    @"includeImage" : appPrefs[@"includeImage"] ?: @YES,
    @"imageMaxWidth" : appPrefs[@"imageMaxWidth"]
        ?: @(PUSHER_DEFAULT_MAX_WIDTH),
    @"imageMaxHeight" : appPrefs[@"imageMaxHeight"]
        ?: @(PUSHER_DEFAULT_MAX_HEIGHT),
    @"imageShrinkFactor" : appPrefs[@"imageShrinkFactor"]
        ?: @(PUSHER_DEFAULT_SHRINK_FACTOR)
  };
}

+ (BOOL)shouldIncludeIconForConfig:(NSPushServiceConfig*)config {
  return NSPReceiverBool(config.rawPrefs[@"includeIcon"]);
}

+ (BOOL)shouldIncludeImageForConfig:(NSPushServiceConfig*)config {
  return NSPReceiverBool(config.rawPrefs[@"includeImage"]);
}

@end
