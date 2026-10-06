// SpringBoard injection hook.
//
// This is the only significant Logos in the project. Everything it does is
// forward an event into Swift: the hook installs an extra selector on BBServer
// and routes published bulletins into `NSPushEngine`. All the logic — filters,
// payload building, transport, logging — lives in the Swift Core.
//
// Why Logos at all: `%hook`/`%orig` splice into a method whose signature is
// known only to the private framework, and `%init` selects a hook group per iOS
// version. Expressing that with the plain ObjC runtime is possible but strictly
// more code for no benefit, so the hook boundary keeps Logos and everything
// behind it is Swift.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <BulletinBoard/BBBulletin.h>
#import <BulletinBoard/BBServer.h>

#import "Pusher-Swift.h"
#import "Pusher-Bridging-Header.h"

// MARK: - Config reload

/// Darwin notifications can arrive on any thread; reloading the config there
/// would race with `handleBulletin:` reading the snapshot on the main thread, so
/// the reload is hopped to the main queue.
static void PusherPrefsChanged(CFNotificationCenterRef center,
                               void *observer,
                               CFStringRef name,
                               const void *object,
                               CFDictionaryRef userInfo) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSPushEngine sharedInstance] reloadConfig];
  });
}

/// Whether the current process is `bundleID`.
static BOOL PusherIsBundle(NSString *bundleID) {
  return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:bundleID];
}

// MARK: - BBServer hooks

// Every hook group forwards into the same two Swift methods. The selector that
// does the forwarding is added once, in the `SB` group; the per-version groups
// only differ in which private method publishes a bulletin.
%group PusherBridge

%hook BBServer

/// Keeps the adapter's `server` reference current. The adapter is the only
/// place that resolves SpringBoard objects into the pipeline's value types.
- (void)_addObserver:(id)observer {
  [NSPBulletinAdapter sharedInstance].server = self;
  %orig;
}

/// Installed by us, not overridden: the per-version hooks call it.
%new
- (void)sendBulletinToPusher:(BBBulletin *)bulletin {
  [[NSPushEngine sharedInstance] handleBulletin:bulletin];
}

%end // %hook BBServer
%end // %group PusherBridge

// MARK: - Per-version publish hooks

// The method that publishes a bulletin changed across iOS versions. Each group
// forwards to the same `sendBulletinToPusher:` added above.

%group iOS10And11
%hook BBServer
- (void)publishBulletin:(BBBulletin *)bulletin
           destinations:(unsigned long long)destinations
     alwaysToLockScreen:(BOOL)alwaysToLockScreen {
  %orig;
  if ([self respondsToSelector:@selector(sendBulletinToPusher:)]) {
    [self sendBulletinToPusher:bulletin];
  }
}
%end
%end // %group iOS10And11

%group iOS12
%hook BBServer
- (void)publishBulletin:(BBBulletin *)bulletin
           destinations:(unsigned long long)destinations {
  %orig;
  if ([self respondsToSelector:@selector(sendBulletinToPusher:)]) {
    [self sendBulletinToPusher:bulletin];
  }
}
%end
%end // %group iOS12

%group iOS13AndLater
%hook BBServer
- (void)publishBulletinRequest:(BBBulletin *)bulletin
                  destinations:(unsigned long long)destinations {
  %orig;
  if ([self respondsToSelector:@selector(sendBulletinToPusher:)]) {
    [self sendBulletinToPusher:bulletin];
  }
}
%end
%end // %group iOS13AndLater

// MARK: - Entry point

%ctor {
  if (PusherIsBundle(@"com.apple.springboard")) {
    if ([[UIDevice currentDevice].systemVersion compare:@"12.0" options:NSNumericSearch] == NSOrderedAscending) {
      %init(iOS10And11);
    } else if ([[UIDevice currentDevice].systemVersion compare:@"13.0" options:NSNumericSearch] == NSOrderedAscending) {
      %init(iOS12);
    } else {
      %init(iOS13AndLater);
    }

    // Prime the config before the first bulletin arrives, then keep it fresh.
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    PusherPrefsChanged,
                                    (__bridge CFStringRef)NSPushEngine.prefsChangedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    [[NSPushEngine sharedInstance] reloadConfig];

    %init(PusherBridge);
  }
}
