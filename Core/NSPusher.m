#import "NSPusher.h"
#import "NSPushConstants.h"
#import "NSPBBServer.h"
#import "../helpers.h"
#import "NSPushConfig.h"
#import "NSPushFilter.h"
#import "NSPushLog.h"
#import "NSPushRequestSender.h"
#import "NSPushService.h"
#import "NSPushSupport.h"

@implementation NSPusher {
  NSMutableArray* _recentNotificationTitles;
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
    _recentNotificationTitles = [NSMutableArray new];
  }
  return self;
}

- (void)reloadConfig {
  _config = [NSPushPrefs loadSnapshot];
}

// Called from the BBServer hook every time a bulletin is published. Guards,
// global prefs filter, loop prevention, then fan-out to all enabled services.
- (void)handleBulletin:(BBBulletin*)bulletin {
  if (!bulletin) {
    XLog(@"Bulletin nil");
    return;
  }
  if (!bulletin.date) {
    bulletin.date = [NSDate date];
  }

  // lastInterruptDate is nil when the bulletin was never actually presented
  // (e.g. right after SpringBoard restarts and replays queued bulletins).
  if (!bulletin.lastInterruptDate) {
    XLog(@"Not forwarding, Last Interrupt Date: %@",
         bulletin.lastInterruptDate);
    [NSPushLog
        addToLogIfEnabledForService:@""
                           bulletin:bulletin
                              label:@"Last interrupt date nil (this should "
                                    @"only happen if SpringBoard just "
                                    @"restarted; if some other time, there is "
                                    @"a problem)"
                             object:nil];
    return;
  }

  if (!NSClassFromString(@"SBApplicationController") ||
      ![NSClassFromString(@"SBApplicationController") sharedInstance]) {
    XLog(@"SpringBoard not ready");
    [NSPushLog addToLogIfEnabledForService:@""
                                  bulletin:bulletin
                                     label:@"SpringBoard not ready"
                                    object:nil];
    return;
  }

  NSString* appID = bulletin.sectionID;
  SBApplication* app = [[NSClassFromString(@"SBApplicationController")
      sharedInstance] applicationWithBundleIdentifier:appID];
  NSString* appName = app && app.displayName && app.displayName.length > 0
                          ? app.displayName
                          : XStr(@"Unknown App: %@", appID);

  NSString* prefsResponse =
      [NSPushFilter globalReasonIfAnyWithServer:self.server
                                       bulletin:bulletin
                                         config:self.config];
  if (prefsResponse) {
    XLog(@"Prefs say no: %@", prefsResponse);
    [NSPushLog
        addToLogIfEnabledForService:@""
                           bulletin:bulletin
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
                           bulletin:bulletin
                              label:XStr(@"Blocked by global app list (%@)",
                                         self.config.globalAppListIsBlacklist
                                             ? @"blacklist"
                                             : @"whitelist")
                             object:nil];
    return;
  }

  NSString* title = XStr(@"%@%@", appName,
                         (bulletin.title && bulletin.title.length > 0
                              ? XStr(@": %@", bulletin.title)
                              : @""));
  NSString* message = @"";
  if (bulletin.showsSubtitle && bulletin.subtitle &&
      bulletin.subtitle.length > 0) {
    message = bulletin.subtitle;
  }
  message = XStr(
      @"%@%@%@", message,
      (message.length > 0 && bulletin.message && bulletin.message.length > 0
           ? @"\n"
           : @""),
      bulletin.message ? bulletin.message : @"");

  // Loop prevention: a forwarded push can itself produce a notification that
  // would get forwarded again. Count how many times this exact title already
  // appeared in the recent window and only drop it once it repeats enough
  // times (10 of the last 25) to look like a genuine loop, so a legitimate
  // single duplicate isn't mistaken for one.
  NSUInteger titleCount = 0;
  for (NSString* recentNotificationTitle in _recentNotificationTitles) {
    if (XEq(title, recentNotificationTitle)) {
      titleCount++;
    }
  }
  if (titleCount >= PUSHER_LOOP_PREVENTION_THRESHOLD) {
    XLog(@"Prevented loop");
    [NSPushLog addToLogIfEnabledForService:@""
                                  bulletin:bulletin
                                     label:@"Prevented loop"
                                    object:nil];
    return;
  }
  // Cap the history as a sliding window: drop the oldest entry once the
  // window fills up, instead of clearing the whole array. Clearing would reset
  // the duplicate count mid-loop, so a genuine loop (THRESHOLD repeats within
  // the last WINDOW notifications) could never be detected.
  while (_recentNotificationTitles.count >= PUSHER_LOOP_PREVENTION_WINDOW) {
    [_recentNotificationTitles removeObjectAtIndex:0];
  }
  [_recentNotificationTitles addObject:title];

  if (self.config.enabledServiceNames.count == 0) {
    XLog(@"No services enabled!");
    return;
  }

  for (NSString* service in self.config.enabledServiceNames) {
    [self sendToService:service
               bulletin:bulletin
                  appID:appID
                appName:appName
                  title:title
                message:message
                 isTest:NO];
  }
}

// Per-service pipeline: look up the service class, skip loops back to the
// service's own app, then apply app-list / SNS / device-condition filters
// before building and sending the request.
- (void)sendToService:(NSString*)service
             bulletin:(BBBulletin*)bulletin
                appID:(NSString*)appID
              appName:(NSString*)appName
                title:(NSString*)title
              message:(NSString*)message
               isTest:(BOOL)isTest {
  NSPushServiceConfig* serviceConfig = self.config.serviceConfigs[service];
  if (!serviceConfig) {
    return;
  }
  Class<NSPPushService> serviceClass =
      (Class<NSPPushService>)[NSPushServiceManager serviceClassForName:service];

  // A push forwarded to a service whose own iOS app just generated the
  // notification would bounce straight back and loop.
  if (!isTest && XEq(appID, [serviceClass loopPreventionAppID])) {
    XLog(@"Prevented loop from same app");
    [NSPushLog addToLogIfEnabledForService:service
                                  bulletin:bulletin
                                     label:@"Prevented loop from same app"
                                    object:nil];
    return;
  }

  NSPushServiceConfig* effectiveConfig = serviceConfig;
  if (!isTest) {
    NSString* appListResponse =
        [NSPushFilter appListReasonIfAnyWithConfig:serviceConfig appID:appID];
    if (appListResponse) {
      XLog(@"[S:%@] Blocked by app list: %@", service, appID);
      [NSPushLog addToLogIfEnabledForService:service
                                    bulletin:bulletin
                                       label:appListResponse
                                      object:nil];
      return;
    }

    BBSectionInfo* sectionInfo =
        [self.server _sectionInfoForSectionID:bulletin.sectionID effective:YES];
    if (!sectionInfo) {
      XLog(@"[S:%@,A:%@] sectionInfo nil", service, appID);
      [NSPushLog
          addToLogIfEnabledForService:service
                             bulletin:bulletin
                                label:@"sectionInfo is nil, it should not be"
                               object:nil];
      return;
    }
    XLog(@"[S:%@,A:%@] Doing SNS", service, appID);
    NSString* snsResponse =
        [NSPushFilter snsReasonIfAnyWithSNS:serviceConfig.sns
                                sectionInfo:sectionInfo
                                      isAnd:serviceConfig.snsIsAnd
                            requireANWithOR:serviceConfig.snsRequireANWithOR];
    if (snsResponse) {
      XLog(@"[S:%@,A:%@] SNS said no: %@", service, appID, snsResponse);
      [NSPushLog addToLogIfEnabledForService:service
                                    bulletin:bulletin
                                       label:snsResponse
                                      object:nil];
      return;
    } else {
      XLog(@"[S:%@,A:%@] SNS ok", service, appID);
    }

    XLog(@"[S:%@,A:%@] Doing Device Conditions", service, appID);
    NSString* deviceConditionsResponse = [NSPushFilter
        deviceReasonIfAnyWithWhenToPush:(int)serviceConfig.whenToPush
                            whatNetwork:(int)serviceConfig.whatNetwork];
    if (deviceConditionsResponse) {
      XLog(@"[S:%@,A:%@] Device Conditions said no: %@", service, appID,
           deviceConditionsResponse);
      [NSPushLog addToLogIfEnabledForService:service
                                    bulletin:bulletin
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
  // on the main thread where the SpringBoard/BBServer objects live, but
  // building the payload can do heavy work (decoding/shrinking the attachment
  // image, generating the icon) that must not stall SpringBoard. Everything
  // used below is thread-safe: NSPushLog and the request sender's retry map
  // use @synchronized, NSURLSession and WeChat's token cache are safe to use
  // from background queues, and bulletin/config are read-only model objects.
  dispatch_async(
      dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSPBulletinContext* context = [NSPBulletinContext
            contextWithBulletin:bulletin
                          appID:appID
                        appName:appName
                          title:title
                        message:message
                         isTest:isTest];
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
                                    service, appName);
                               if (!isTest) {
                                 [NSPushLog
                                     addToLogIfEnabledForService:service
                                                        bulletin:bulletin
                                                           label:
                                                               @"Failed to "
                                                               @"build request"
                                                          object:nil];
                               }
                               return;
                             }
                             // The HTTP method is a per-service user pref;
                             // apply it on top of the service's default.
                             request.method = XStrDefault(
                                 effectiveConfig.rawPrefs[@"method"], @"POST");
                             [[NSPushRequestSender sharedInstance]
                                 sendRequest:request
                                   logString:XStr(@"[S:%@,A:%@]", service,
                                                  appName)
                                     service:service
                                    bulletin:bulletin];
                             XLog(@"[S:%@,T:%d,A:%@] Pushed", service, isTest,
                                  appName);
                             if (!isTest) {
                               [NSPushLog addToLogIfEnabledForService:service
                                                             bulletin:bulletin
                                                                label:@"Pushed"
                                                               object:nil];
                             }
                           }];
      });
}

@end
