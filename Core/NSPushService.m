#import "NSPushService.h"
#import "NSPushConstants.h"
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
  NSString* dateStr = [self dateStringForDate:context.date config:config];

  NSMutableDictionary* data = [@{
    @"deviceName" : UIDevice.currentDevice.name,
    @"appName" : context.appName ?: @"",
    @"appID" : context.appID ?: @"",
    @"title" : context.title ?: @"",
    @"subtitle" : context.subtitle ?: @"",
    @"message" : context.message ?: @"",
    @"date" : dateStr ?: @""
  } mutableCopy];

  if ([self shouldIncludeIconForConfig:config]) {
    // The provider resolves the icon through SpringBoard on demand and may hop
    // to the main thread; it returns nil when no icon is available, in which
    // case the field is simply omitted.
    UIImage* icon =
        context.iconImageProvider ? context.iconImageProvider() : nil;
    NSString* iconBase64 = [NSPushImage base64RepresentationForImage:icon];
    if (iconBase64) {
      data[@"icon"] = iconBase64;
    }
  }

  if ([self shouldIncludeImageForConfig:config]) {
    // Rather than trusting a hard-coded attachment type, try to load the
    // attachment URL as an image; it is a file URL on disk.
    NSURL* URL = context.attachmentURL;
    if (URL) {
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

+ (NSArray*)logImageDataProperties {
  // Default: the shared data dict keys. Subclasses override to match their own
  // body layout (e.g. return @[] when they have no Base64 image fields).
  return PUSHER_LOG_IMAGE_DATA_PROPERTIES;
}

+ (NSDictionary*)logInfoDictForInfoDict:(NSDictionary*)infoDict {
  NSMutableDictionary* logInfoDict = [infoDict mutableCopy];
  for (NSString* prop in [self logImageDataProperties]) {
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
