#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BBBulletin;
@class BBServer;
@class NSPBulletinContext;
@class NSPDeviceState;

// The single SpringBoard boundary of the push pipeline.
//
// Everything that needs BulletinBoard / SpringBoard private classes lives
// here: the current BBServer, the per-app BBSectionInfo, app display names
// (SBApplicationController), app icons (SBIconController), and the lock-screen
// and Wi-Fi device state (SBLockScreenManager / SBWiFiManager). Each is
// converted into the plain value objects declared in NSPushSupport.h, so no
// other file below the hook has to import
// BulletinBoard/SpringBoard.
//
// NSPusher.handleBulletin: (called from the BBServer hook in Tweak.xm) is the
// only consumer on the hot path: it converts the bulletin once and the rest of
// the pipeline sees only the resulting NSPBulletinContext.
@interface NSPBulletinAdapter : NSObject

+ (instancetype)sharedInstance;

// The live BBServer, set from the BBServer hook (see Tweak.xm). nil until the
// hook has run (e.g. shortly after a SpringBoard restart).
@property(nonatomic, strong) BBServer* server;

// YES once SpringBoard's application controller is up; the pipeline cannot
// resolve app names before that.
+ (BOOL)isSpringBoardReady;

// NO when the bulletin was never actually presented by SpringBoard
// (lastInterruptDate is nil), e.g. for queued bulletins replayed right after a
// SpringBoard restart. Such bulletins must not be forwarded.
+ (BOOL)wasPresented:(BBBulletin*)bulletin;

// Convert one bulletin into the pipeline's value object: appID, app name,
// composed display strings, date (defaulted when the bulletin has none),
// attachment URL, a lazy icon provider and the app's notification settings.
// Returns nil when bulletin is nil.
+ (NSPBulletinContext*)contextForBulletin:(BBBulletin*)bulletin;

// Same conversion for synthetic test-push bulletins, where the caller supplies
// the display strings and app name instead of deriving them (see NSPTestPush).
+ (NSPBulletinContext*)contextForBulletin:(BBBulletin*)bulletin
                                   isTest:(BOOL)isTest
                                  appName:(NSString*)appName
                             displayTitle:(NSString*)displayTitle
                           displayMessage:(NSString*)displayMessage;

// Current device conditions, snapshotted so the filter stays a pure function.
+ (NSPDeviceState*)currentDeviceState;

// Resolve an app icon through SpringBoard's icon model. May be called from a
// background queue (it hops to the main thread, because SBIconController and
// SBIconModel are SpringBoard UI objects). Returns nil when no icon is
// available.
+ (UIImage*)iconImageForBundleID:(NSString*)bundleID;

@end