#import "NSPusher.h"
#import "../global.h"
#import "../helpers.h"
#import "NSPBulletinContext.h"
#import "NSPushConfigSnapshot.h"
#import "NSPushFilter.h"
#import "NSPushLog.h"
#import "NSPushPrefs.h"
#import "NSPushRequestSender.h"
#import "NSPushService.h"
#import "NSPushServiceConfig.h"
#import "NSPushServiceManager.h"

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

- (void)handleBulletin:(BBBulletin*)bulletin {
  if (!bulletin) {
    XLog(@"Bulletin nil");
    return;
  }
  if (!bulletin.date) {
    bulletin.date = [NSDate date];
  }

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
      [self.config.globalAppList containsObject:appID.lowercaseString];
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

  for (NSString* recentNotificationTitle in _recentNotificationTitles) {
    if (XEq(title, XStr(@"%@: %@", appName, recentNotificationTitle))) {
      XLog(@"Prevented loop");
      [NSPushLog addToLogIfEnabledForService:@""
                                    bulletin:bulletin
                                       label:@"Prevented loop"
                                      object:nil];
      return;
    }
  }
  if (_recentNotificationTitles.count >= 50) {
    [_recentNotificationTitles removeAllObjects];
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
        [NSPushFilter snsReasonIfAnyWithSNS:serviceConfig.sns.allKeys
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

    effectiveConfig = [serviceConfig effectiveConfigForAppID:appID];
  }

  PusherAuthorizationType authType =
      (PusherAuthorizationType)[serviceClass authTypeForConfig:effectiveConfig];
  NSDictionary* infoDict =
      [serviceClass infoDictForBulletinContext:[NSPBulletinContext
                                                   contextWithBulletin:bulletin
                                                                 appID:appID
                                                               appName:appName
                                                                 title:title
                                                               message:message
                                                                isTest:isTest]
                                        config:effectiveConfig];
  NSDictionary* credentials =
      [serviceClass credentialsForConfig:effectiveConfig];

  [serviceClass
      fetchDynamicKeyForConfig:effectiveConfig
                    completion:^(NSString* dynamicKey) {
                      NSString* method = XStrDefault(
                          effectiveConfig.rawPrefs[@"method"], @"POST");
                      [[NSPushRequestSender sharedInstance]
                          sendRequestWithURLString:
                              [serviceClass URLStringForConfig:effectiveConfig]
                                          infoDict:infoDict
                                       credentials:credentials
                                        dynamicKey:dynamicKey
                                          authType:(PusherAuthorizationType)
                                                       authType
                                            method:method
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
}

@end
