#import "NSPBulletinAdapter.h"
#import "NSPBBServer.h"
#import "NSPushSupport.h"
#import "helpers.h"
#import "iOSVersion.h"

@interface NSPBulletinAdapter ()
// The app's settings, or nil with *reason set to a human-readable explanation
// (the messages the filters used to produce themselves).
+ (NSPushNotificationSettings*)settingsForAppID:(NSString*)appID
                                         reason:(NSString**)reason;
+ (NSString*)appNameForAppID:(NSString*)appID;
+ (NSString*)displayTitleForAppName:(NSString*)appName
                              title:(NSString*)title;
+ (NSString*)displayMessageForSubtitle:(NSString*)subtitle
                               message:(NSString*)message
                          showsSubtitle:(BOOL)showsSubtitle;
@end

@implementation NSPBulletinAdapter

+ (instancetype)sharedInstance {
  static NSPBulletinAdapter* sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [self new];
  });
  return sharedInstance;
}

+ (BOOL)isSpringBoardReady {
  Class applicationController = NSClassFromString(@"SBApplicationController");
  return applicationController &&
         [applicationController sharedInstance] != nil;
}

+ (BOOL)wasPresented:(BBBulletin*)bulletin {
  return bulletin.lastInterruptDate != nil;
}

+ (NSPBulletinContext*)contextForBulletin:(BBBulletin*)bulletin {
  return [self contextForBulletin:bulletin
                           isTest:NO
                          appName:nil
                     displayTitle:nil
                   displayMessage:nil];
}

+ (NSPBulletinContext*)contextForBulletin:(BBBulletin*)bulletin
                                   isTest:(BOOL)isTest
                                  appName:(NSString*)appName
                             displayTitle:(NSString*)displayTitle
                           displayMessage:(NSString*)displayMessage {
  if (!bulletin) {
    return nil;
  }

  NSString* appID = bulletin.sectionID;
  NSPBulletinContext* context = [NSPBulletinContext new];
  context.appID = appID ?: @"";
  context.bulletinID = bulletin.bulletinID;
  // Default the date here (instead of mutating the bulletin) so the context
  // always carries the timestamp the log and the date string rely on.
  context.date = bulletin.date ?: [NSDate date];
  context.isTest = isTest;

  context.title = bulletin.title;
  context.subtitle = bulletin.subtitle;
  context.message = bulletin.message;

  context.appName = appName ?: [self appNameForAppID:appID];
  if (displayTitle || displayMessage) {
    // Test pushes supply their own display strings.
    context.displayTitle = displayTitle;
    context.displayMessage = displayMessage;
  } else {
    context.displayTitle = [self displayTitleForAppName:context.appName
                                                  title:bulletin.title];
    BOOL showsSubtitle = bulletin.showsSubtitle;
    context.displayMessage =
        [self displayMessageForSubtitle:bulletin.subtitle
                                message:bulletin.message
                          showsSubtitle:showsSubtitle];
  }

  BBAttachmentMetadata* attachment = bulletin.primaryAttachment;
  context.attachmentURL = attachment.URL;

  // Capture only the bundle ID string, never the bulletin: the provider is
  // called later, from the background queue that builds the payload.
  NSString* bundleID = appID;
  context.iconImageProvider = ^{
    return [NSPBulletinAdapter iconImageForBundleID:bundleID];
  };

  NSString* reason = nil;
  context.notificationSettings = [self settingsForAppID:appID reason:&reason];
  context.notificationSettingsUnavailableReason = reason;

  return context;
}

+ (NSPushNotificationSettings*)settingsForAppID:(NSString*)appID
                                         reason:(NSString**)reason {
  BBServer* server = [self sharedInstance].server;
  if (!server) {
    if (reason) {
      *reason = @"Server is nil, it shouldn't be";
    }
    return nil;
  }

  BBSectionInfo* sectionInfo =
      [server _sectionInfoForSectionID:appID effective:YES];
  if (!sectionInfo) {
    if (reason) {
      *reason = @"Section info is nil, it shouldn't be";
    }
    return nil;
  }

  if (reason) {
    *reason = nil;
  }

  NSPushNotificationSettings* settings = [NSPushNotificationSettings new];
  settings.allowsNotifications = sectionInfo.allowsNotifications;
  settings.showsInLockScreen = sectionInfo.showsInLockScreen;
  settings.showsInNotificationCenter = sectionInfo.showsInNotificationCenter;
  settings.showsMessagePreview = sectionInfo.showsMessagePreview;
  settings.isBanner =
      sectionInfo.alertType == BBSectionInfoAlertTypeBanner;
  settings.showsBadges =
      (sectionInfo.pushSettings & BBActualSectionInfoPushSettingsBadges) != 0;
  settings.showsSounds =
      (sectionInfo.pushSettings & BBActualSectionInfoPushSettingsSounds) != 0;
  return settings;
}

+ (NSString*)appNameForAppID:(NSString*)appID {
  SBApplication* app = [[NSClassFromString(@"SBApplicationController")
      sharedInstance] applicationWithBundleIdentifier:appID];
  if (app && app.displayName && app.displayName.length > 0) {
    return app.displayName;
  }
  return XStr(@"Unknown App: %@", appID);
}

+ (NSString*)displayTitleForAppName:(NSString*)appName
                              title:(NSString*)title {
  return XStr(@"%@%@", appName,
              (title && title.length > 0 ? XStr(@": %@", title) : @""));
}

+ (NSString*)displayMessageForSubtitle:(NSString*)subtitle
                               message:(NSString*)message
                          showsSubtitle:(BOOL)showsSubtitle {
  // The subtitle is only part of the message when the bulletin says it is
  // being shown.
  NSString* displayMessage = @"";
  if (showsSubtitle && subtitle && subtitle.length > 0) {
    displayMessage = subtitle;
  }
  return XStr(@"%@%@%@", displayMessage,
              (displayMessage.length > 0 && message && message.length > 0
                   ? @"\n"
                   : @""),
              message ?: @"");
}

+ (NSPDeviceState*)currentDeviceState {
  NSPDeviceState* deviceState = [NSPDeviceState new];
  deviceState.locked =
      ((SBLockScreenManager*)[NSClassFromString(@"SBLockScreenManager")
           sharedInstance])
          .isUILocked;
  deviceState.wifiName =
      [[NSClassFromString(@"SBWiFiManager") sharedInstance] currentNetworkName];
  return deviceState;
}

+ (UIImage*)iconImageForBundleID:(NSString*)bundleID {
  if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) {
    return nil;
  }

  // SBIconController / SBIconModel are SpringBoard UI objects that should only
  // be touched on the main thread. The push pipeline builds payloads on a
  // background queue, so hop to the main thread when needed.
  if (![NSThread isMainThread]) {
    __block UIImage* result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      result = [NSPBulletinAdapter iconImageForBundleID:bundleID];
    });
    return result;
  }

  SBApplicationIcon* icon =
      [((SBIconController*)[NSClassFromString(@"SBIconController")
            sharedInstance]).model expectedIconForDisplayIdentifier:bundleID];
  if (!icon) {
    return nil;
  }

  if (SYSTEM_VERSION_LESS_THAN(@"13.0")) {
    return [icon generateIconImage:2];
  }

  struct SBIconImageInfo imageInfo;
  imageInfo.size = CGSizeMake(60, 60);
  imageInfo.scale = [UIScreen mainScreen].scale;
  imageInfo.continuousCornerRadius = 12;
  return [icon generateIconImageWithInfo:imageInfo];
}

@end