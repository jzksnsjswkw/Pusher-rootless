#define isBundle(z) [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:z]

#import "Core/NSPushService.h"
#import "Core/NSPusher.h"
#import "NSPTestPush.h"
#import "global.h"
#import "helpers.h"
#import "iOSVersion.h"
#import "UIImage+ReplaceColor.h"
#import "Preferences/NSPusherManager.h"

// Darwin notifications can arrive on any thread; reloading the config there
// would race with handleBulletin: reading self.config on the main thread
// (non-atomic ivar), so hop to the main queue first.
static void pusherPrefsChanged() {
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSPusher sharedInstance] reloadConfig];
  });
}

%group SB
%hook BBServer

%new
+ (BBServer*)pusherSharedInstance {
  return [NSPusher sharedInstance].server;
}

- (void)_addObserver:(id)arg1 {
  [NSPusher sharedInstance].server = self;
  %orig;
}

%new
- (void)sendBulletinToPusher:(BBBulletin*)bulletin {
  [[NSPusher sharedInstance] handleBulletin:bulletin];
}

%new
- (void)sendToPusherService:(NSString*)service
                   bulletin:(BBBulletin*)bulletin
                      appID:(NSString*)appID
                    appName:(NSString*)appName
                      title:(NSString*)title
                    message:(NSString*)message
                     isTest:(BOOL)isTest {
  [[NSPusher sharedInstance] sendToService:service
                                  bulletin:bulletin
                                     appID:appID
                                   appName:appName
                                     title:title
                                   message:message
                                    isTest:isTest];
}

%end // %hook BBServer
%end // %group SB

%group iOS10And11
%hook BBServer
- (void)publishBulletin:(BBBulletin*)bulletin
           destinations:(unsigned long long)arg2
     alwaysToLockScreen:(BOOL)arg3 {
  %orig;
  if ([self respondsToSelector:@selector(sendBulletinToPusher:)]) {
    [self sendBulletinToPusher:bulletin];
  }
}
%end // %hook BBServer
%end // %group iOS10And11

%group iOS12
%hook BBServer
- (void)publishBulletin:(BBBulletin*)bulletin
           destinations:(unsigned long long)arg2 {
  %orig;
  if ([self respondsToSelector:@selector(sendBulletinToPusher:)]) {
    [self sendBulletinToPusher:bulletin];
  }
}
%end // %hook BBServer
%end // %group iOS12

%group iOS13And14
%hook BBServer
- (void)publishBulletinRequest:(BBBulletin*)bulletin
                  destinations:(unsigned long long)arg2 {
  %orig;
  if ([self respondsToSelector:@selector(sendBulletinToPusher:)]) {
    [self sendBulletinToPusher:bulletin];
  }
}
%end // %hook BBServer
%end // %group iOS13

%group Preferences
%hook PSTableCell

- (void)setIcon:(UIImage*)icon {
  if (icon && self.superview &&
      [self.superview isKindOfClass:UITableView.class] &&
      self.superview.superview &&
      [self.superview.superview respondsToSelector:@selector(_viewDelegate)] &&
      ([self.superview.superview._viewDelegate
           isKindOfClass: %c(NSPPSListControllerWithColoredUI)] ||
       [self.superview.superview._viewDelegate
           isKindOfClass: %c(NSPPSViewControllerWithColoredUI)])) {
    UIImage *newIcon =
        [icon imageByReplacingColor:PUSHER_COLOR
                          withColor:((NSPusherManager *)[%c(NSPusherManager)
                                         sharedController])
                                        .activeTintColor];
    %orig(newIcon);
  } else {
    %orig;
  }
}

%end // %hook PSTableCell
%end // %group Preferences

%ctor {
if (isBundle(@"com.apple.springboard")) {

  if (SYSTEM_VERSION_LESS_THAN(@"12.0")) {
          %init(iOS10And11);
  } else if (SYSTEM_VERSION_LESS_THAN(@"13.0")) {
          %init(iOS12);
  } else {
          %init(iOS13And14);
  }

  CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);
  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                  NULL,
                                  (CFNotificationCallback)pusherPrefsChanged,
                                  CFSTR(PUSHER_PREFS_NOTIFICATION), NULL,
                                  CFNotificationSuspensionBehaviorCoalesce);
  pusherPrefsChanged();
  [NSPTestPush load];
      %init(SB);
} else if (isBundle(@"com.apple.Preferences")) {
      %init(Preferences);
}
}
