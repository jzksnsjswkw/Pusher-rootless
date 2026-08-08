#import <UIKit/UIKit.h>

@interface NSPushImage : NSObject

+ (NSString*)base64RepresentationForImage:(UIImage*)image;
+ (UIImage*)shrinkImage:(UIImage*)image byFactor:(CGFloat)factor;
+ (NSString*)base64IconDataForBundleID:(NSString*)bundleID;

@end
