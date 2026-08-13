#import "NSPushService.h"
#import "../global.h"
#import "../helpers.h"
#import "NSPushConfig.h"
#import "NSPushSupport.h"
#import "Services/NSPBarkService.h"
#import "Services/NSPCustomService.h"
#import "Services/NSPFeishuService.h"
#import "Services/NSPIFTTTService.h"
#import "Services/NSPPushbulletService.h"
#import "Services/NSPPusherReceiverService.h"
#import "Services/NSPPushoverService.h"
#import "Services/NSPWechatService.h"
#import <UIKit/UIKit.h>

@implementation NSPushServiceManager

+ (Class)serviceClassForName:(NSString*)name {
  static NSDictionary* registry;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    registry = @{
      PUSHER_SERVICE_PUSHOVER : NSPPushoverService.class,
      PUSHER_SERVICE_PUSHBULLET : NSPPushbulletService.class,
      PUSHER_SERVICE_IFTTT : NSPIFTTTService.class,
      PUSHER_SERVICE_PUSHER_RECEIVER : NSPPusherReceiverService.class,
      PUSHER_SERVICE_FEISHU : NSPFeishuService.class,
      PUSHER_SERVICE_BARK : NSPBarkService.class,
      PUSHER_SERVICE_WECHAT : NSPWechatService.class
    };
  });
  return registry[name] ?: NSPCustomService.class;
}

+ (NSArray*)builtinServiceNames {
  return BUILTIN_PUSHER_SERVICES;
}

@end

@implementation NSPushServiceBase

+ (NSString*)serviceName {
  return nil;
}

+ (NSString*)loopPreventionAppID {
  return @"";
}

+ (NSDictionary*)headersForConfig:(NSPushServiceConfig*)config {
  return @{};
}

+ (NSDictionary*)extraPrefsForName:(NSString*)name
                      servicePrefs:(NSDictionary*)servicePrefs {
  return @{};
}

+ (NSDictionary*)extraCustomAppPrefsForName:(NSString*)name
                                    appPrefs:(NSDictionary*)appPrefs {
  return @{};
}

+ (NSString*)urlForEventName:(NSString*)eventName
                      dbName:(NSString*)dbName
                   serverURL:(NSString*)serverURL {
  return @"";
}

+ (void)URLStringForConfig:(NSPushServiceConfig*)config
                completion:(void (^)(NSString* urlString))completion {
  completion([self URLStringForConfig:config]);
}

+ (NSString*)URLStringForConfig:(NSPushServiceConfig*)config {
  // Abstract: subclasses must override the sync URL builder (or the async
  // variant). Raising here fails loudly if a service forgets.
  [self doesNotRecognizeSelector:_cmd];
  return nil;
}

+ (NSDictionary*)infoDictForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  return [self baseInfoDictForBulletinContext:context config:config];
}

+ (BOOL)shouldIncludeIconForConfig:(NSPushServiceConfig*)config {
  return NO;
}

+ (BOOL)shouldIncludeImageForConfig:(NSPushServiceConfig*)config {
  return NO;
}

+ (NSDictionary*)baseInfoDictForBulletinContext:(NSPBulletinContext*)context
                                         config:(NSPushServiceConfig*)config {
  BBBulletin* bulletin = context.bulletin;

  NSString* dateStr = [self dateStringForDate:bulletin.date config:config];

  NSMutableDictionary* data = [@{
    @"deviceName" : UIDevice.currentDevice.name,
    @"appName" : context.appName ?: @"",
    @"appID" : bulletin.sectionID ?: @"",
    @"title" : bulletin.title ?: @"",
    @"subtitle" : bulletin.subtitle ?: @"",
    @"message" : bulletin.message ?: @"",
    @"date" : dateStr ?: @""
  } mutableCopy];

  if ([self shouldIncludeIconForConfig:config]) {
    data[@"icon"] = [NSPushImage base64IconDataForBundleID:bulletin.sectionID];
  }

  if ([self shouldIncludeImageForConfig:config]) {
    BBAttachmentMetadata* metadata = bulletin.primaryAttachment;
    // Rather than trusting a hard-coded attachment type, try to load the
    // attachment URL as an image; the metadata.URL is a file URL on disk.
    if (metadata && metadata.URL) {
      NSURL* URL = metadata.URL;
      UIImage* image = [UIImage imageWithContentsOfFile:URL.path];
      if (!image) {
        // Fall back to the raw data in case the URL is not a plain file path.
        NSData* rawData = [NSData dataWithContentsOfURL:URL];
        image = [UIImage imageWithData:rawData];
      }
      if (image) {
        NSNumber* imageShrinkFactor = config.rawPrefs[@"imageShrinkFactor"];
        if (imageShrinkFactor) {
          data[@"imageShrinkFactor"] = imageShrinkFactor;
        }

        NSNumber* imageMaxWidth = config.rawPrefs[@"imageMaxWidth"];
        NSNumber* imageMaxHeight = config.rawPrefs[@"imageMaxHeight"];
        CGFloat widthShrinkFactor = 0.0;
        CGFloat heightShrinkFactor = 0.0;

        if (imageMaxWidth && imageMaxWidth.floatValue > 0.0 &&
            image.size.width > imageMaxWidth.floatValue) {
          widthShrinkFactor = image.size.width / imageMaxWidth.floatValue;
        }
        if (imageMaxHeight && imageMaxHeight.floatValue > 0.0 &&
            image.size.height > imageMaxHeight.floatValue) {
          heightShrinkFactor = image.size.height / imageMaxHeight.floatValue;
        }

        // if either has a value, shrink with the largest factor
        if (widthShrinkFactor + heightShrinkFactor > 0.0) {
          CGFloat shrinkFactor = widthShrinkFactor > heightShrinkFactor
                                     ? widthShrinkFactor
                                     : heightShrinkFactor;
          image = [NSPushImage shrinkImage:image byFactor:shrinkFactor];
        }

        data[@"image"] = image;
      }
      // give true value so even if can't figure out how to send image, can
      // still tell that there is one
      if (!data[@"image"]) {
        data[@"image"] = @YES;
      }
    }
  }

  return data;
}

@end

@implementation NSPushServiceBase (Shared)

+ (NSString*)dateStringForDate:(NSDate*)date
                        config:(NSPushServiceConfig*)config {
  NSDateFormatter* dateFormatter = [NSDateFormatter new];
  [dateFormatter setDateFormat:XStrDefault(config.rawPrefs[@"dateFormat"],
                                           @"MMM d, h:mm a")];
  return [dateFormatter stringFromDate:date];
}

@end
