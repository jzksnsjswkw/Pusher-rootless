#import "NSPushServiceBase.h"
#import "../helpers.h"
#import "NSPBulletinContext.h"
#import "NSPushImage.h"
#import "NSPushServiceConfig.h"
#import <UIKit/UIKit.h>

@implementation NSPushServiceBase

+ (NSString*)serviceName {
  return nil;
}

+ (NSString*)loopPreventionAppID {
  return @"";
}

+ (PusherAuthorizationType)authTypeForConfig:(NSPushServiceConfig*)config {
  return PusherAuthorizationTypeReplaceKey;
}

+ (NSDictionary*)credentialsForConfig:(NSPushServiceConfig*)config {
  return @{@"key" : config.rawPrefs[@"key"] ?: @""};
}

+ (NSString*)URLStringForConfig:(NSPushServiceConfig*)config {
  return config.rawPrefs[@"url"] ?: @"";
}

+ (NSDictionary*)infoDictForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  return [self baseInfoDictForBulletinContext:context config:config];
}

+ (void)fetchDynamicKeyForConfig:(NSPushServiceConfig*)config
                      completion:(void (^)(NSString* key))completion {
  completion(@"");
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
    if (metadata && metadata.type == 1) { // assume image type is 1
      NSURL* URL = metadata.URL;
      if (URL) {
        UIImage* image = [UIImage imageWithContentsOfFile:URL.path];
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
