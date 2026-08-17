#import "NSPushService.h"
#import "NSPushConstants.h"
#import "NSPBBServer.h"
#import "../helpers.h"
#import "NSPushConfig.h"
#import "NSPushSupport.h"
#import "Services/NSPCustomService.h"
#import "../Generated/BuiltinServices.generated.h"
#import <UIKit/UIKit.h>

@implementation NSPushServiceManager

static NSMutableDictionary<NSString*, Class>* gServiceRegistry;
static dispatch_once_t gServiceRegistryToken;

+ (void)registerServiceClass:(Class)serviceClass forName:(NSString*)name {
  dispatch_once(&gServiceRegistryToken, ^{
    gServiceRegistry = [NSMutableDictionary new];
  });
  if (name.length > 0) {
    gServiceRegistry[name] = serviceClass;
  }
}

+ (Class)serviceClassForName:(NSString*)name {
  dispatch_once(&gServiceRegistryToken, ^{
    gServiceRegistry = [NSMutableDictionary new];
  });
  Class cls = gServiceRegistry[name];
  return cls ?: NSPCustomService.class;
}

@end

@implementation NSPushServiceBase

+ (NSString*)serviceName {
  return nil;
}

+ (NSDictionary*)extraPrefsForName:(NSString*)name
                      servicePrefs:(NSDictionary*)servicePrefs {
  return @{};
}

+ (NSDictionary*)extraCustomAppPrefsForName:(NSString*)name
                                    appPrefs:(NSDictionary*)appPrefs {
  return @{};
}

+ (NSString*)replacedKeyURLStringForConfig:(NSPushServiceConfig*)config {
  NSString* key = XStrDefault(config.rawPrefs[@"key"], @"");
  NSString* url = XStrDefault(config.rawPrefs[@"url"], @"");
  return [url stringByReplacingOccurrencesOfString:@"REPLACE_KEY"
                                         withString:key];
}

+ (NSString*)urlForEventName:(NSString*)eventName
                      dbName:(NSString*)dbName
                   serverURL:(NSString*)serverURL {
  return @"";
}

+ (void)requestForBulletinContext:(NSPBulletinContext*)context
                           config:(NSPushServiceConfig*)config
                       completion:(void (^)(NSPushRequest* request))completion {
  completion([self requestForBulletinContext:context config:config]);
}

+ (NSPushRequest*)requestForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  // Abstract: subclasses must override the sync request builder (or the async
  // variant). Raising here fails loudly if a service forgets.
  [self doesNotRecognizeSelector:_cmd];
  return nil;
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
        id imageShrinkFactorValue = config.rawPrefs[@"imageShrinkFactor"];
        if (imageShrinkFactorValue) {
          data[@"imageShrinkFactor"] = imageShrinkFactorValue;
        }

        // Guard the type before floatValue: NSString is also accepted because
        // Preferences edit cells commonly store text values as NSString.
        id imageMaxWidthValue = config.rawPrefs[@"imageMaxWidth"];
        id imageMaxHeightValue = config.rawPrefs[@"imageMaxHeight"];
        CGFloat imageMaxWidth = 0.0;
        CGFloat imageMaxHeight = 0.0;
        if ([imageMaxWidthValue isKindOfClass:NSNumber.class] ||
            [imageMaxWidthValue isKindOfClass:NSString.class]) {
          imageMaxWidth = [imageMaxWidthValue floatValue];
        }
        if ([imageMaxHeightValue isKindOfClass:NSNumber.class] ||
            [imageMaxHeightValue isKindOfClass:NSString.class]) {
          imageMaxHeight = [imageMaxHeightValue floatValue];
        }
        CGFloat widthShrinkFactor = 0.0;
        CGFloat heightShrinkFactor = 0.0;

        if (imageMaxWidth > 0.0 && image.size.width > imageMaxWidth) {
          widthShrinkFactor = image.size.width / imageMaxWidth;
        }
        if (imageMaxHeight > 0.0 && image.size.height > imageMaxHeight) {
          heightShrinkFactor = image.size.height / imageMaxHeight;
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

+ (NSDictionary*)logInfoDictForInfoDict:(NSDictionary*)infoDict {
  NSMutableDictionary* logInfoDict = [infoDict mutableCopy];
  for (NSString* prop in PUSHER_LOG_IMAGE_DATA_PROPERTIES) {
    if (logInfoDict[prop]) {
      logInfoDict[prop] = PUSHER_LOG_IMAGE_DATA_REPLACEMENT;
    }
  }
  // imageShrinkFactor is an internal retry hint, never part of the real body.
  [logInfoDict removeObjectForKey:@"imageShrinkFactor"];
  return logInfoDict;
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
