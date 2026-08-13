#import "NSPushSupport.h"
#import "../global.h"
#import "../helpers.h"
#import "iOSVersion.m"

@implementation NSPBulletinContext

+ (instancetype)contextWithBulletin:(BBBulletin*)bulletin
                              appID:(NSString*)appID
                            appName:(NSString*)appName
                              title:(NSString*)title
                            message:(NSString*)message
                             isTest:(BOOL)isTest {
  NSPBulletinContext* context = [self new];
  context.bulletin = bulletin;
  context.appID = appID;
  context.appName = appName;
  context.title = title;
  context.message = message;
  context.isTest = isTest;
  return context;
}

- (NSString*)retryKeyForService:(NSString*)service {
  return XStr(@"%@_%@_%@", self.bulletin.bulletinID ?: @"empty_bulletin_id",
              self.bulletin.sectionID, service);
}

@end

@implementation NSPushImage

+ (NSString*)base64RepresentationForImage:(UIImage*)image {
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

+ (NSString*)base64IconDataForBundleID:(NSString*)bundleID {
  SBApplicationIcon* icon =
      [((SBIconController*)[NSClassFromString(@"SBIconController")
            sharedInstance]).model expectedIconForDisplayIdentifier:bundleID];
  UIImage* image = nil;

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
