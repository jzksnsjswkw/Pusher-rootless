#import <BulletinBoard/BBBulletin.h>
#import <UIKit/UIKit.h>

@interface NSPBulletinContext : NSObject

@property(nonatomic, strong) BBBulletin* bulletin;
@property(nonatomic, copy) NSString* appID;
@property(nonatomic, copy) NSString* appName;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* message;
@property(nonatomic, assign) BOOL isTest;

+ (instancetype)contextWithBulletin:(BBBulletin*)bulletin
                              appID:(NSString*)appID
                            appName:(NSString*)appName
                              title:(NSString*)title
                            message:(NSString*)message
                             isTest:(BOOL)isTest;

@end

@interface NSPushImage : NSObject

+ (NSString*)base64RepresentationForImage:(UIImage*)image;
+ (UIImage*)shrinkImage:(UIImage*)image byFactor:(CGFloat)factor;
+ (NSString*)base64IconDataForBundleID:(NSString*)bundleID;

@end
