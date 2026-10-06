#import "NSPusher.h"
#import "NSPushConstants.h"
#import "NSPBulletinAdapter.h"
#import "../helpers.h"
#import "NSPushConfig.h"
#import "NSPushFilter.h"
#import "NSPushLog.h"
#import "NSPushRequestSender.h"
#import "NSPushService.h"
#import "NSPushSupport.h"

@implementation NSPusher {
  NSMutableArray* _recentNotificationContents;
}

+ (instancetype)sharedInstance {
  static NSPusher* sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [self new];
  });
  return sharedInstance;
}

- (instancetype)init {
  if (self = [super init]) {
    _recentNotificationContents = [NSMutableArray new];
  }
  return self;
}

- (void)reloadConfig {
  _config = [NSPushPrefs loadSnapshot];
}

// Called from the BBServer hook every time a bulletin is published.
//
// This is the SpringBoard boundary: the bulletin is converted once into an
// NSPBulletinContext value object here, and the rest of the pipeline (filters,
// request sender, service payload builders) only ever sees that. See
// NSPBulletinAdapter.h.
- (void)handleBulletin:(BBBulletin*)bulletin {
  if (!bulletin) {
    XLog(@"Bulletin nil");
    return;
  }

  NSPBulletinContext* context =
      [NSPBulletinAdapter contextForBulletin:bulletin];

  // Bulletins SpringBoard never actually presented (no lastInterruptDate) are
  // queued bulletins being replayed, e.g. right after a SpringBoard restart.
  if (![NSPBulletinAdapter wasPresented:bulletin]) {
    XLog(@"Not forwarding, bulletin was never presented");
    [NSPushLog
        addToLogIfEnabledForService:@""
                           context:context
                              label:@"Last interrupt date nil (this should "
                                    @"only happen if SpringBoard just "
                                    @"restarted; if some other time, there is "
                                    @"a problem)"
                             object:nil];
    return;
  }

  if (![NSPBulletinAdapter isSpringBoardReady]) {
    XLog(@"SpringBoard not ready");
    [NSPushLog addToLogIfEnabledForService:@""
                                  context:context
                                     label:@"SpringBoard not ready"
                                    object:nil];
    return;
  }

  // Guards passed: global prefs filter, loop prevention, then fan-out to all
  // enabled services.
  NSString* appID = context.appID;
  NSString* prefsResponse =
      [NSPushFilter globalReasonIfAnyWithContext:context config:self.config];
  if (prefsResponse) {
    XLog(@"Prefs say no: %@", prefsResponse);
    [NSPushLog
        addToLogIfEnabledForService:@""
                           context:context
                              label:XStr(@"Global prefs: %@", prefsResponse)
                             object:nil];
    return;
  }

  BOOL appListContainsApp =
      [self.config.globalAppList containsObject:appID];
  if (self.config.globalAppListIsBlacklist == appListContainsApp) {
    XLog(@"[Global] Blocked by app list: %@", appID);
    [NSPushLog
        addToLogIfEnabledForService:@""
                           context:context
                              label:XStr(@"Blocked by global app list (%@)",
                                         self.config.globalAppListIsBlacklist
                                             ? @"blacklist"
                                             : @"whitelist")
                             object:nil];
    return;
  }

  // Loop prevention: a forwarded push can itself produce a notification that
  // would get forwarded again. Count how many times this exact bulletin
  // content already appeared in the recent window and only drop it once it
  // repeats enough times (10 of the last 25) to look like a genuine loop, so
  // a legitimate single duplicate isn't mistaken for one.
  NSString* bulletinContent =
      XStr(@"%@\n%@\n%@", context.displayTitle, context.subtitle ?: @"",
           context.message ?: @"");
  NSUInteger contentCount = 0;
  for (NSString* recentContent in _recentNotificationContents) {
    if (XEq(bulletinContent, recentContent)) {
      contentCount++;
    }
  }
  if (contentCount >= PUSHER_LOOP_PREVENTION_THRESHOLD) {
    XLog(@"Prevented loop");
    [NSPushLog addToLogIfEnabledForService:@""
                                  context:context
                                     label:@"Prevented loop"
                                    object:nil];
    return;
  }
  // Cap the history as a sliding window: drop the oldest entry once the
  // window fills up, instead of clearing the whole array. Clearing would reset
  // the duplicate count mid-loop, so a genuine loop (THRESHOLD repeats within
  // the last WINDOW notifications) could never be detected.
  while (_recentNotificationContents.count >= PUSHER_LOOP_PREVENTION_WINDOW) {
    [_recentNotificationContents removeObjectAtIndex:0];
  }
  [_recentNotificationContents addObject:bulletinContent];

  if (self.config.enabledServiceNames.count == 0) {
    XLog(@"No services enabled!");
    return;
  }

  for (NSString* service in self.config.enabledServiceNames) {
    [self sendToService:service context:context];
  }
}

// Per-service pipeline: look up the service class, then apply app-list / SNS /
// device-condition filters before building and sending the request.
- (void)sendToService:(NSString*)service context:(NSPBulletinContext*)context {
  NSString* appID = context.appID;
  NSPushServiceConfig* serviceConfig = self.config.serviceConfigs[service];
  if (!serviceConfig) {
    return;
  }
  Class<NSPPushService> serviceClass =
      (Class<NSPPushService>)[NSPushServiceManager serviceClassForName:service];

  NSPushServiceConfig* effectiveConfig = serviceConfig;
  if (!context.isTest) {
    NSString* appListResponse =
        [NSPushFilter appListReasonIfAnyWithConfig:serviceConfig appID:appID];
    if (appListResponse) {
      XLog(@"[S:%@] Blocked by app list: %@", service, appID);
      [NSPushLog addToLogIfEnabledForService:service
                                    context:context
                                       label:appListResponse
                                      object:nil];
      return;
    }

    // The settings were snapshotted from BBSectionInfo by the adapter; the
    // global filter above already rejected a bulletin without them, so this is
    // only a guard for callers that skip it.
    NSPushNotificationSettings* settings = context.notificationSettings;
    if (!settings) {
      XLog(@"[S:%@,A:%@] sectionInfo nil", service, appID);
      NSString* reason = context.notificationSettingsUnavailableReason;
      if (!reason) {
        reason = @"sectionInfo is nil, it should not be";
      }
      [NSPushLog addToLogIfEnabledForService:service
                                    context:context
                                       label:reason
                                      object:nil];
      return;
    }
    XLog(@"[S:%@,A:%@] Doing SNS", service, appID);
    NSString* snsResponse =
        [NSPushFilter snsReasonIfAnyWithSNS:serviceConfig.sns
                                   settings:settings
                                      isAnd:serviceConfig.snsIsAnd
                            requireANWithOR:serviceConfig.snsRequireANWithOR];
    if (snsResponse) {
      XLog(@"[S:%@,A:%@] SNS said no: %@", service, appID, snsResponse);
      [NSPushLog addToLogIfEnabledForService:service
                                    context:context
                                       label:snsResponse
                                      object:nil];
      return;
    } else {
      XLog(@"[S:%@,A:%@] SNS ok", service, appID);
    }

    XLog(@"[S:%@,A:%@] Doing Device Conditions", service, appID);
    NSPDeviceState* deviceState = [NSPBulletinAdapter currentDeviceState];
    NSString* deviceConditionsResponse = [NSPushFilter
        deviceReasonIfAnyWithWhenToPush:(int)serviceConfig.whenToPush
                            whatNetwork:(int)serviceConfig.whatNetwork
                            deviceState:deviceState];
    if (deviceConditionsResponse) {
      XLog(@"[S:%@,A:%@] Device Conditions said no: %@", service, appID,
           deviceConditionsResponse);
      [NSPushLog addToLogIfEnabledForService:service
                                    context:context
                                       label:deviceConditionsResponse
                                      object:nil];
      return;
    } else {
      XLog(@"[S:%@,A:%@] Device Conditions ok", service, appID);
    }

    // Per-app overrides (customApps) replace the service-wide prefs for this
    // specific app.
    effectiveConfig = [serviceConfig effectiveConfigForAppID:appID];
  }

  // Build and send on a background queue: the filter decision (above) is done
  // on the main thread where the SpringBoard objects live, but building the
  // payload can do heavy work (decoding/shrinking the attachment image,
  // generating the icon) that must not stall SpringBoard. Everything used
  // below is thread-safe: the context and config are read-only value objects,
  // NSPushLog and the request sender's retry map use @synchronized, and
  // NSURLSession and WeChat's token cache are safe to use from background
  // queues.
  dispatch_async(
      dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // The request may resolve asynchronously (e.g. WeChat access token);
        // send it only once the final request is known.
        [serviceClass
            requestForBulletinContext:context
                               config:effectiveConfig
                           completion:^(NSPushRequest* request) {
                             if (!request) {
                               // Service failed to build a request (e.g. WeChat
                               // couldn't fetch an access token); log the
                               // failure and skip the send.
                               XLog(@"[S:%@,A:%@] Failed to build request",
                                    service, context.appName);
                               if (!context.isTest) {
                                 [NSPushLog
                                     addToLogIfEnabledForService:service
                                                        context:context
                                                           label:
                                                               @"Failed to "
                                                               @"build request"
                                                          object:nil];
                               }
                               return;
                             }
                             // The service is responsible for fully assembling
                             // the request (URL, headers, body, method, body
                             // encoding). The main framework sends it as-is.
                             [[NSPushRequestSender sharedInstance]
                                 sendRequest:request
                                   logString:XStr(@"[S:%@,A:%@]", service,
                                                  context.appName)
                                     service:service
                                     context:context];
                             XLog(@"[S:%@,T:%d,A:%@] Pushed", service,
                                  context.isTest, context.appName);
                             if (!context.isTest) {
                               [NSPushLog
                                   addToLogIfEnabledForService:service
                                                      context:context
                                                         label:@"Pushed"
                                                        object:nil];
                             }
                           }];
      });
}

@end