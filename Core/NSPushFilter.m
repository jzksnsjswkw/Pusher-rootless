#import "NSPushFilter.h"
#import "NSPushConfig.h"
#import "NSPushConstants.h"
#import "NSPBBServer.h"
#import "helpers.h"

@implementation NSPushFilter

+ (NSString*)globalReasonIfAnyWithServer:(BBServer*)server
                                bulletin:(BBBulletin*)bulletin
                                  config:(NSPushConfigSnapshot*)config {
  XLog(@"-------Bulletin------- %@", bulletin.sectionID);
  if (!config.enabled) {
    return XStr(@"Pusher %@abled", config.enabled ? @"En" : @"Dis");
  }

  if (bulletin.sectionID &&
      XEq(bulletin.sectionID, PUSHER_TEST_NOTIFICATION_SECTION_ID) &&
      bulletin.title && XEq(bulletin.title, @"Pusher") && bulletin.message &&
      [bulletin.message hasPrefix:PUSHER_TEST_PUSH_RESULT_PREFIX]) {
    return @"Not forwarding test notification result banner";
  }

  if (!config.globalAppList ||
      ![config.globalAppList isKindOfClass:NSArray.class]) {
    return XStr(@"Global app list is nil, it shouldn't be. %@",
                config.globalAppList);
  }

  if (!server) {
    return @"Server is nil, it shouldn't be";
  }

  BBSectionInfo* sectionInfo =
      [server _sectionInfoForSectionID:bulletin.sectionID effective:YES];
  if (!sectionInfo) {
    return @"Section info is nil, it shouldn't be";
  }

  if (!config.enabledServiceNames ||
      ![config.enabledServiceNames isKindOfClass:NSArray.class]) {
    return XStr(@"Enabled services is nil, it shouldn't be. %@",
                config.enabledServiceNames);
  }

  for (NSString* service in config.enabledServiceNames) {
    id serviceConfig = config.serviceConfigs[service];
    if (!serviceConfig ||
        ![serviceConfig isKindOfClass:NSPushServiceConfig.class]) {
      return @"Service prefs are nil, they shouldn't be";
    }
  }

  return nil;
}

+ (NSString*)appListReasonIfAnyWithConfig:(NSPushServiceConfig*)config
                                    appID:(NSString*)appID {
  NSPushServiceConfig* serviceConfig = (NSPushServiceConfig*)config;
  NSArray* serviceAppList = [serviceConfig.appList isKindOfClass:NSArray.class]
                                   ? serviceConfig.appList
                                   : @[];
  BOOL appListContainsApp =
      [serviceAppList containsObject:appID];
  BOOL appListIsBlacklist = serviceConfig.appListIsBlacklist;
  if (appListIsBlacklist == appListContainsApp) {
    return XStr(@"Blocked by app list (%@)",
                appListIsBlacklist ? @"blacklist" : @"whitelist");
  }
  return nil;
}

+ (NSString*)snsReasonIfAnyWithSNS:(NSArray*)sns
                       sectionInfo:(BBSectionInfo*)sectionInfo
                             isAnd:(BOOL)isAnd
                   requireANWithOR:(BOOL)requireANWithOR {
  if (!isAnd && requireANWithOR && !sectionInfo.allowsNotifications) {
    return @"'OR' and 'Require Allow Notifications with OR' both on, but Allow "
           @"Notifications is disabled in this app's settings.";
  }

  // No filter conditions configured: nothing to check, let the notification
  // through. (An empty list with OR used to block everything because the loop
  // below never found anything "sufficient", unlike AND which returned nil.)
  if (sns.count == 0) {
    return nil;
  }

  BOOL foundSufficient = NO;
  for (NSString* key in sns) {
    BOOL sufficient = NO;
    if (XEq(key, PUSHER_SUFFICIENT_ALLOW_NOTIFICATIONS_KEY)) {
      sufficient = sectionInfo.allowsNotifications;
    } else if (XEq(key, PUSHER_SUFFICIENT_LOCK_SCREEN_KEY)) {
      sufficient = sectionInfo.showsInLockScreen;
    } else if (XEq(key, PUSHER_SUFFICIENT_NOTIFICATION_CENTER_KEY)) {
      sufficient = sectionInfo.showsInNotificationCenter;
    } else if (XEq(key, PUSHER_SUFFICIENT_BANNERS_KEY)) {
      sufficient = sectionInfo.alertType == BBSectionInfoAlertTypeBanner;
    } else if (XEq(key, PUSHER_SUFFICIENT_BADGES_KEY)) {
      sufficient = (sectionInfo.pushSettings &
                    BBActualSectionInfoPushSettingsBadges) != 0;
    } else if (XEq(key, PUSHER_SUFFICIENT_SOUNDS_KEY)) {
      sufficient = (sectionInfo.pushSettings &
                    BBActualSectionInfoPushSettingsSounds) != 0;
    } else if (XEq(key, PUSHER_SUFFICIENT_SHOWS_PREVIEWS_KEY)) {
      sufficient = sectionInfo.showsMessagePreview;
    } else {
      // Unknown/misspelled condition key: treat it as not satisfied so a
      // config typo can't silently bypass the filter. This is defensive only;
      // getSNSKeys only produces the known keys.
      XLog(@"Unknown SNS condition key: %@", key);
    }
    // AND, so if any one is insufficient, just return right away
    if (isAnd && !sufficient) {
      return XStr(@"'AND' but %@ incorrect", key);
      // OR, so just one sufficient is enough
    } else if (!isAnd && sufficient) {
      XLog(@"OR and sufficient: %@", key);
      foundSufficient = YES;
      break;
    }
  }

  // None passed as sufficient before, so insufficient if OR. We must track
  // foundSufficient explicitly: the plain `break` above used to fall through
  // to this check and block every notification in OR mode, even when a
  // condition had just matched.
  if (!isAnd && !foundSufficient) {
    XLog(@"OR and insufficient");
    return @"'OR' and none were correct";
  }

  return nil;
}

+ (NSString*)deviceReasonIfAnyWithWhenToPush:(int)whenToPush
                                 whatNetwork:(int)whatNetwork {
  BOOL deviceIsLocked =
      ((SBLockScreenManager*)[NSClassFromString(@"SBLockScreenManager")
           sharedInstance])
          .isUILocked;
  NSString* wifiName =
      [[NSClassFromString(@"SBWiFiManager") sharedInstance] currentNetworkName];
  BOOL onWiFi = wifiName != nil;
  if ((whatNetwork == PUSHER_WHAT_NETWORK_WIFI_ONLY && !onWiFi) ||
      (whatNetwork == PUSHER_WHAT_NETWORK_OFF_WIFI_ONLY && onWiFi)) {
    return XStr(@"What Network set to %@ but %@on WiFi",
                (whatNetwork == PUSHER_WHAT_NETWORK_WIFI_ONLY
                     ? @"WiFi Only"
                     : (whatNetwork == PUSHER_WHAT_NETWORK_OFF_WIFI_ONLY
                            ? @"Cellular Only"
                            : @"Any Network")),
                onWiFi ? @"" : @"not ");
  }
  if ((whenToPush == PUSHER_WHEN_TO_PUSH_LOCKED && !deviceIsLocked) ||
      (whenToPush == PUSHER_WHEN_TO_PUSH_UNLOCKED && deviceIsLocked)) {
    return XStr(
        @"When to Push set to %@ but device %@locked",
        (whenToPush == PUSHER_WHEN_TO_PUSH_LOCKED
             ? @"Locked"
             : (whenToPush == PUSHER_WHEN_TO_PUSH_UNLOCKED ? @"Unlocked"
                                                           : @"Either")),
        deviceIsLocked ? @"" : @"un");
  }
  return nil;
}

@end
