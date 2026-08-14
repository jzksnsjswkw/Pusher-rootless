// Private SpringBoard / BulletinBoard interfaces used by the Core pipeline and
// the SpringBoard-side hooks (Tweak.xm, NSPTestPush.xm). Declarations only —
// everything is resolved at runtime via NSClassFromString / Logos %c(), so no
// extra linking is required beyond what global.h already needed.

#import <UIKit/UIKit.h>
#import <BulletinBoard/BBBulletin.h>
#import <BulletinBoard/BBSectionInfo.h>
#import <BulletinBoard/BBServer.h>
#import <SpringBoard/SBApplication.h>
#import <SpringBoard/SBApplicationController.h>

typedef NS_OPTIONS(NSUInteger, BBActualSectionInfoPushSettings) {
  BBActualSectionInfoPushSettingsBadges = 1 << 3, // was 0
  BBActualSectionInfoPushSettingsSounds = 1 << 4, // was 1
  // BBSectionInfoPushSettingsAlerts = 1 << 2 // wrong
};

@interface BBAttachmentMetadata : NSObject
@property(nonatomic, readonly) long long type;
@property(nonatomic, copy, readonly) NSURL* URL;
- (id)_initWithUUID:(id)arg1 type:(long long)arg2 URL:(id)arg3;
// iOS 14
- (id)_initWithType:(long long)arg1
                              URL:(id)arg2
                       identifier:(id)arg3
                      uniformType:(id)arg4
       thumbnailGeneratorUserInfo:(id)arg5
                  thumbnailHidden:(BOOL)arg6
    hiddenFromDefaultExpandedView:(BOOL)arg7;
@end

@interface BBBulletin (Pusher)
@property(nonatomic, readonly) BOOL showsSubtitle;
@property(nonatomic, copy) BBAttachmentMetadata* primaryAttachment;
// @property (nonatomic, copy) NSArray *additionalAttachments;
@end

@interface BBServer (Pusher)
- (BBSectionInfo*)_sectionInfoForSectionID:(id)arg1 effective:(BOOL)arg2;
+ (BBServer*)pusherSharedInstance;
- (void)sendBulletinToPusher:(BBBulletin*)bulletin;
- (void)sendToPusherService:(NSString*)service
                   bulletin:(BBBulletin*)bulletin
                      appID:(NSString*)appID
                    appName:(NSString*)appName
                      title:(NSString*)title
                    message:(NSString*)message
                     isTest:(BOOL)isTest;
@end

@interface SBLockScreenManager
+ (id)sharedInstance;
@property(readonly) BOOL isUILocked;
@end

// iOS 13
typedef struct SBIconImageInfo {
  CGSize size;
  CGFloat scale;
  CGFloat continuousCornerRadius;
} SBIconImageInfo;

@interface SBApplicationIcon : NSObject
// iOS 12 and below
- (UIImage*)generateIconImage:(int)arg1;
// iOS 13
- (id)generateIconImageWithInfo:(SBIconImageInfo)arg1;
@end

@interface SBIconModel : NSObject
- (SBApplicationIcon*)expectedIconForDisplayIdentifier:(id)arg1;
@end

@interface SBIconController : UIViewController
@property(nonatomic, retain) SBIconModel* model;
+ (id)sharedInstance;
@end

@interface SBWiFiManager : NSObject
+ (id)sharedInstance;
- (NSString*)currentNetworkName;
@end