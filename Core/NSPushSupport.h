#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Value objects and small helpers for the push pipeline.
//
// Dependency rule: everything below the SpringBoard hook works on the plain
// value objects declared here and must not import BulletinBoard / SpringBoard.
// SpringBoard types (BBBulletin, BBSectionInfo, SBIconController, ...) are
// converted exactly once, at the hook boundary, by NSPBulletinAdapter; see
// NSPBulletinAdapter.h. That keeps the filter, the request sender and the
// service payload builders testable and independent of SpringBoard's private
// classes.

// The per-app notification settings the SNS filter is evaluated against.
// Mirrors the subset of BBSectionInfo that the filter used to read, so the
// filter never has to touch BulletinBoard. Populated by NSPBulletinAdapter.
@interface NSPushNotificationSettings : NSObject

@property(nonatomic, assign) BOOL allowsNotifications;
@property(nonatomic, assign) BOOL showsInLockScreen;
@property(nonatomic, assign) BOOL showsInNotificationCenter;
@property(nonatomic, assign) BOOL showsMessagePreview;
// sectionInfo.alertType == BBSectionInfoAlertTypeBanner.
@property(nonatomic, assign) BOOL isBanner;
// sectionInfo.pushSettings & (Badges | Sounds).
@property(nonatomic, assign) BOOL showsBadges;
@property(nonatomic, assign) BOOL showsSounds;

@end

// The device conditions the "when to push" / "what network" filter checks.
// These used to be read straight from SBLockScreenManager / SBWiFiManager
// inside the filter; now the adapter snapshots them so the filter is a pure
// function of its inputs. Populated by NSPBulletinAdapter.
@interface NSPDeviceState : NSObject

@property(nonatomic, assign, getter=isLocked) BOOL locked;
// nil when the device is not associated with a Wi-Fi network.
@property(nonatomic, copy) NSString* wifiName;

@end

// One bulletin reduced to plain values: the pipeline's data model.
//
// Populated by NSPBulletinAdapter -- the only thing that knows about
// BBBulletin -- and treated as read-only by everything downstream (the
// filters, the request sender, the service payload builders and the log).
@interface NSPBulletinContext : NSObject

// Identity.
@property(nonatomic, copy) NSString* appID; // bulletin.sectionID
@property(nonatomic, copy) NSString* appName; // the app's display name
@property(nonatomic, copy) NSString* bulletinID;
@property(nonatomic, copy) NSDate* date; // never nil
@property(nonatomic, assign) BOOL isTest;

// Raw bulletin content, exactly as BBBulletin carried it. Used by the shared
// data dict (IFTTT / Pusher Receiver / custom services), by Feishu, and by the
// loop-prevention and test-result-banner checks.
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* subtitle;
@property(nonatomic, copy) NSString* message;

// Composed display strings: "AppName: title" and subtitle + message. Used by
// the services that send a single headed notification (Bark, Pushover,
// Pushbullet, Wechat, IFTTT's curated format).
@property(nonatomic, copy) NSString* displayTitle;
@property(nonatomic, copy) NSString* displayMessage;

// The bulletin's primary attachment file, nil when it has none. The shared
// data dict loads it as an image for the services that ask for images.
@property(nonatomic, copy) NSURL* attachmentURL;

// Lazily resolves the app icon, nil when none is available. Kept as a provider
// rather than a value because only some services want the icon and resolving
// it is expensive (SpringBoard icon generation plus PNG encoding); it may hop
// to the main thread, so it is safe to call from a background queue.
@property(nonatomic, copy) UIImage* (^iconImageProvider)(void);

// Settings for this app, nil when SpringBoard has no section info for it; in
// that case notificationSettingsUnavailableReason explains why.
@property(nonatomic, strong) NSPushNotificationSettings* notificationSettings;
@property(nonatomic, copy) NSString* notificationSettingsUnavailableReason;

@end

// Image helpers shared by the payload builders (UIKit only).
@interface NSPushImage : NSObject

// nil when image is nil.
+ (NSString*)base64RepresentationForImage:(UIImage*)image;
+ (UIImage*)shrinkImage:(UIImage*)image byFactor:(CGFloat)factor;

@end