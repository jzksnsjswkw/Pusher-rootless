#import "NSPushSupport.h"

@implementation NSPushNotificationSettings
@end

@implementation NSPDeviceState
@end

// All properties are populated by NSPBulletinAdapter; see NSPushSupport.h.
@implementation NSPBulletinContext
@end

@implementation NSPushImage

+ (NSString*)base64RepresentationForImage:(UIImage*)image {
  if (!image) {
    return nil;
  }
  NSData* iconData = UIImagePNGRepresentation(image);
  return [iconData
      base64EncodedStringWithOptions:NSDataBase64EncodingEndLineWithLineFeed];
}

+ (UIImage*)shrinkImage:(UIImage*)image byFactor:(CGFloat)factor {
  CGSize newSize =
      CGSizeMake(image.size.width / factor, image.size.height / factor);
  UIGraphicsBeginImageContext(newSize);
  [image drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
  UIImage* smallImage = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return smallImage;
}

@end