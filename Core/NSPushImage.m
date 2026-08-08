#import <UIKit/UIKit.h>
#import "NSPushImage.h"
#import "global.h"
#import "iOSVersion.m"

@implementation NSPushImage

+ (NSString *)base64RepresentationForImage:(UIImage *)image {
  NSData *iconData = UIImagePNGRepresentation(image);
  return [iconData
      base64EncodedStringWithOptions:NSDataBase64EncodingEndLineWithLineFeed];
}

+ (UIImage *)shrinkImage:(UIImage *)image byFactor:(CGFloat)factor {
  CGSize newSize =
      CGSizeMake(image.size.width / factor, image.size.height / factor);
  UIGraphicsBeginImageContext(newSize);
  [image drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
  UIImage *smallImage = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return smallImage;
}

+ (NSString *)base64IconDataForBundleID:(NSString *)bundleID {
  SBApplicationIcon *icon =
      [((SBIconController *)[NSClassFromString(@"SBIconController")
                               sharedInstance])
          .model expectedIconForDisplayIdentifier:bundleID];
  UIImage *image = nil;

  if (SYSTEM_VERSION_LESS_THAN(@"13.0")) {
    image = [icon generateIconImage:2];
  } else {
    struct SBIconImageInfo imageInfo;
    imageInfo.size = CGSizeMake(60, 60);
    imageInfo.scale = [UIScreen mainScreen].scale;
    imageInfo.continuousCornerRadius = 12;
    image = [icon generateIconImageWithInfo:imageInfo];
  }

  return [NSPushImage base64RepresentationForImage:image];
}

@end
