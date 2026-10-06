// Bridging header for the Pusher Swift sources.
//
// This is the only place the private framework interfaces below the hook are
// declared. Two rules apply:
//
//  1. BulletinBoard is linked by the tweak (and is present in every process
//     that loads it), so its classes may be imported by name.
//
//  2. SpringBoard is NOT linked — the tweak also loads into Preferences.app,
//     which has no SpringBoard.framework, and naming one of its classes from
//     Swift emits a hard `_OBJC_CLASS_$_X` reference that the dynamic linker
//     would then refuse to resolve. SpringBoard is therefore reached through
//     `Runtime` (NSClassFromString + IMP thunks) only.
//
// `FBSSystemService`/`SBLockScreenManager`/`SBIconController`/`SBWiFiManager`
// and friends are consequently declared as `@objc` protocols in Swift
// (see BulletinAdapter.swift) and cast onto runtime-resolved objects.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Path resolution for rootless / roothide installs, and the Darwin
// notification API used to tell the tweak that prefs changed.
#import <notify.h>
#import <roothide.h>

#pragma mark - BulletinBoard (linked)

#import <BulletinBoard/BBBulletin.h>
#import <BulletinBoard/BBSectionInfo.h>
#import <BulletinBoard/BBServer.h>

/// Options in `BBSectionInfo.pushSettings`. The framework header only declares
/// a subset, and the badge/sound bits are not among them.
typedef NS_OPTIONS(NSUInteger, BBActualSectionInfoPushSettings) {
  BBActualSectionInfoPushSettingsBadges = 1 << 3, // was 0
  BBActualSectionInfoPushSettingsSounds = 1 << 4, // was 1
};

@interface BBAttachmentMetadata : NSObject
@property(nonatomic, readonly) long long type;
@property(nonatomic, copy, readonly) NSURL *URL;
- (instancetype)_initWithUUID:(NSString *)arg1
                         type:(long long)arg2
                          URL:(NSURL *)arg3;
// iOS 14
- (instancetype)_initWithType:(long long)arg1
                          URL:(NSURL *)arg2
                   identifier:(NSString *)arg3
                  uniformType:(NSString *)arg4
     thumbnailGeneratorUserInfo:(NSDictionary *)arg5
              thumbnailHidden:(BOOL)arg6
    hiddenFromDefaultExpandedView:(BOOL)arg7;
@end

/// `-[SBIcon generateIconImageWithInfo:]` takes this struct **by value**.
/// It is declared here, in C, because `@convention(c)` can only carry types
/// that are representable in C — a Swift struct is not, even when its fields
/// are. (SpringBoard itself is still reached through the runtime; this is only
/// the argument layout.)
typedef struct {
  CGSize size;
  CGFloat scale;
  CGFloat continuousCornerRadius;
} SBIconImageInfo;

@interface BBBulletin (Pusher)
/// Whether the bulletin's subtitle is shown; also gates the composed message.
@property(nonatomic, readonly) BOOL showsSubtitle;
@property(nonatomic, copy) BBAttachmentMetadata *primaryAttachment;
@end

/// Private `BBServer` accessors. `_sectionInfoForSectionID:effective:` is the
/// one that resolves an app's notification settings.
@interface BBServer (Pusher)
- (BBSectionInfo *)_sectionInfoForSectionID:(id)arg1 effective:(BOOL)arg2;
/// Injected by the hook in PusherHooks.xm; forwards one bulletin to the
/// pipeline.
- (void)sendBulletinToPusher:(BBBulletin *)bulletin;
/// Injected by the hook in PusherHooks.xm; pushes a synthetic test bulletin to
/// one service.
- (void)sendToPusherService:(NSString *)service
                    context:(id)context;
@end

#pragma mark - Test push IPC

#import <AppSupport/CPDistributedMessagingCenter.h>
