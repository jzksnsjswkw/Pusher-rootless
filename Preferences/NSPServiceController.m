#import "NSPServiceController.h"
#import "NSPCustomizeAppsController.h"
#import "NSPSharedSpecifiers.h"

#import "../global.h"
#import "../helpers.h"
#import <notify.h>

@implementation NSPServiceController

- (id)initWithService:(NSString*)service
                image:(UIImage*)image
             isCustom:(BOOL)isCustom {
  if (self = [super init]) {
    _service = service;
    _image = image;
    _isCustom = isCustom;
    _colorCube = [CCColorCube new];
    _uiColor = nil;
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  UNUserNotificationCenter.currentNotificationCenter.delegate = self;

  // [self setTitle:_service];
  if (!_imageTitleView) {
    UILabel* label = [UILabel new];
    label.text = _service;
    label.font = [UIFont boldSystemFontOfSize:17];

    UIImageView* imageView = [[UIImageView alloc] initWithImage:_image];

    _imageTitleView =
        [[UIStackView alloc] initWithArrangedSubviews:@[ imageView, label ]];
    _imageTitleView.alignment = UIStackViewAlignmentCenter;
    _imageTitleView.spacing = 10.0;

    self.navigationItem.titleView = _imageTitleView;
  }
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  if (!_uiColor) {
    CCFlags flags =
        (CCFlags)(CCOnlyDistinctColors | CCAvoidWhite | CCAvoidBlack);
    NSArray* imgColors = [_colorCube extractColorsFromImage:_image flags:flags];
    if (!imgColors.count) {
      // No color extracted: still restore the default tint so the UI doesn't
      // keep the previous service's color.
      [NSPusherManager.sharedController setActiveTintColor:nil];
      [self tintUIToPusherColor];
      return;
    }
    _uiColor = [imgColors[0] copy];
  }

  // load each time to override NSPRootListController
  [NSPusherManager.sharedController setActiveTintColor:_uiColor];
  [self tintUIToPusherColor];
}

- (void)addObjectsFromArray:(NSArray*)source
                    atIndex:(int)idx
                    toArray:(NSMutableArray*)dest {
  for (id object in source) {
    [dest insertObject:object atIndex:idx];
    idx += 1;
  }
}

- (NSArray*)specifiers {
  if (!_specifiers) {
    NSMutableArray* allSpecifiers = nil;
    NSArray* sharedSpecifiers = nil;

    if (_isCustom) {
      allSpecifiers = [[NSPSharedSpecifiers getCustom:_service
                                                  ref:self] mutableCopy];
      sharedSpecifiers = [NSPSharedSpecifiers getCustomShared:_service];
    } else {
      allSpecifiers = [[self loadSpecifiersFromPlistName:_service
                                                  target:self] mutableCopy];
      sharedSpecifiers = [NSPSharedSpecifiers get:_service];
    }

    // Get preferences for counting
    CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
    CFArrayRef keyList = CFPreferencesCopyKeyList(
        PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    NSDictionary* prefs = @{};
    if (keyList) {
      prefs = (__bridge_transfer NSDictionary*)CFPreferencesCopyMultiple(
          keyList, PUSHER_APP_ID, kCFPreferencesCurrentUser,
          kCFPreferencesAnyHost);
      if (!prefs) {
        prefs = @{};
      }
      CFRelease(keyList);
    }

    for (PSSpecifier* specifier in allSpecifiers) {
      if (specifier.cellType == PSLinkCell) {
        if (XEq(specifier.name, @"App List")) {
          int count = 0;
          if (_isCustom) {
            count = [NSPSharedSpecifiers
                countAppIDsWithPrefix:prefs
                               prefix:[specifier propertyForKey:
                                                     @"ALSettingsKeyPrefix"]];
          } else {
            count = (int)[NSPSharedSpecifiers
                        builtInServiceAppListForService:_service]
                        .count;
          }
          specifier.name = XStr(@"%@ (%d total)", specifier.name, count);
          // Store as a non-retaining NSValue: keeping a raw self here creates
          // controller -> specifiers -> psListRef -> controller cycle and the
          // controller is never deallocated.
          [specifier
              setProperty:[NSValue valueWithNonretainedObject:self]
                   forKey:@"psListRef"];
        } else if (XEq(specifier.name, @"App Customization")) {
          NSDictionary* customApps = nil;
          if (_isCustom) {
            customApps = (NSDictionary*)
                prefs[NSPPreferenceCustomServiceCustomAppsKey(_service)];
          } else {
            NSDictionary* builtInServices =
                (NSDictionary*)prefs[NSPPreferenceBuiltInServicesKey] ?: @{};
            customApps =
                builtInServices[_service][NSPPreferenceServiceCustomAppsKey];
          }
          specifier.name = XStr(@"%@ (%d total)", specifier.name,
                                customApps ? (int)customApps.count : 0);
          // Non-retaining NSValue, see comment above.
          [specifier
              setProperty:[NSValue valueWithNonretainedObject:self]
                   forKey:@"psListRef"];
        }
      }
    }

    // Shared specifiers (receiving devices, notification sounds, etc.) are
    // appended at the end of the list. The old code tried to insert them
    // inside an "Options" group by matching specifier.identifier == @"Options",
    // but no plist group cell carries that identifier, so the branch was
    // unreachable and the plain append below is the only path that ever ran.
    [allSpecifiers addObjectsFromArray:sharedSpecifiers];

    NSArray* specialCells = @[ @(PSGroupCell), @(PSButtonCell), @(PSLinkCell) ];

    NSArray* globalSpecifiers =
        [self loadSpecifiersFromPlistName:@"GlobalAndServices" target:self];
    for (PSSpecifier* specifier in globalSpecifiers) {
      [specifier setProperty:_service forKey:@"service"];
      if (specifier.cellType == PSSegmentCell) {
        NSMutableArray* values = [specifier.values mutableCopy];
        NSMutableArray* titles = [NSMutableArray arrayWithObject:@"Default"];
        for (id v in values) {
          [titles addObject:specifier.titleDictionary[v]];
        }
        [values insertObject:@(PUSHER_SEGMENT_CELL_DEFAULT) atIndex:0];
        [specifier setValues:values titles:titles];
        [specifier setProperty:@(PUSHER_SEGMENT_CELL_DEFAULT)
                        forKey:@"default"];
      }
      if (specifier.cellType == PSLinkCell) {
        [specifier setProperty:@(_isCustom) forKey:@"isCustomService"];
      }
      if ([specialCells
              containsObject:@(specifier
                                   .cellType)]) { // don't set these properties
                                                  // on certain specifiers
        continue;
      }
      [specifier setProperty:@NO forKey:@"isCustomApp"];
      // [specifier setProperty:[specifier propertyForKey:@"key"]
      // forKey:@"globalKey"];
      if (_isCustom) {
        specifier->setter = @selector(setPreferenceValue:forCustomSpecifier:);
        specifier->getter = @selector(readCustomPreferenceValue:);
        [specifier setProperty:[specifier propertyForKey:@"customServiceKey"]
                        forKey:@"key"];
      } else {
        specifier->setter =
            @selector(setPreferenceValue:forBuiltInServiceSpecifier:);
        specifier->getter = @selector(readBuiltInServicePreferenceValue:);
        [specifier setProperty:[specifier propertyForKey:@"customServiceKey"]
                        forKey:@"key"];
      }
      specifier.target = NSPSharedSpecifiers.class;
    }
    [allSpecifiers addObjectsFromArray:globalSpecifiers];

    PSSpecifier* sendTestNotificationGroup = [PSSpecifier emptyGroupSpecifier];
    PSSpecifier* sendTestNotification =
        [PSSpecifier preferenceSpecifierNamed:@"Send Test Notification"
                                       target:self
                                          set:nil
                                          get:nil
                                       detail:nil
                                         cell:PSButtonCell
                                         edit:nil];
    [sendTestNotification setButtonAction:@selector(sendTestNotification:)];
    [sendTestNotification setProperty:@YES forKey:@"enabled"];

    [allSpecifiers addObjectsFromArray:@[
      sendTestNotificationGroup, sendTestNotification
    ]];

    _specifiers = [allSpecifiers copy];
  }

  return _specifiers;
}

- (void)sendTestNotification:(PSSpecifier*)specifier {
  [self.view endEditing:YES];

  XLog(@"Sending test for %@", _service);

  CPDistributedMessagingCenter* messagingCenter =
      [CPDistributedMessagingCenter centerNamed:PUSHER_MESSAGING_CENTER_NAME];

  // Two-way (wait for reply)
  NSDictionary* reply = nil;
  @try {
    reply = [messagingCenter
        sendMessageAndReceiveReplyName:PUSHER_TEST_PUSH_MESSAGE_NAME
                              userInfo:@{@"service" : _service}];
  } @catch (NSException* exception) {
    // No server running (e.g. SpringBoard not yet respringed after install);
    // treat as a failed send instead of crashing Preferences.
    XLog(@"Test push exception: %@", exception);
  }

  if (reply[@"success"] && ((NSNumber*)reply[@"success"]).boolValue) {
    [self displayNotification:XStr(@"%@Sent", PUSHER_TEST_PUSH_RESULT_PREFIX)];
  } else {
    [self displayNotification:XStr(@"%@Failed to Send",
                                   PUSHER_TEST_PUSH_RESULT_PREFIX)];
  }
}

- (void)displayNotification:(NSString*)message {
  UNMutableNotificationContent* content = [UNMutableNotificationContent new];
  content.title = kName;
  content.body = message;

  UNNotificationRequest* request =
      [UNNotificationRequest requestWithIdentifier:@"TestNotificationResult"
                                           content:content
                                           trigger:nil];

  [UNUserNotificationCenter.currentNotificationCenter
      addNotificationRequest:request
       withCompletionHandler:^(NSError* error) {
         // XLog(@"addNotificationRequest error: %@", error.description);
         if (error) {
           // This completion handler runs on an arbitrary background queue;
           // hop to the main thread before touching UIKit.
           dispatch_async(dispatch_get_main_queue(), ^{
             UIAlertController* alert = XAlert(message);
             [alert addAction:XAlertBtn(@"Ok")];
             [self presentViewController:alert animated:YES completion:nil];
           });
         }
       }];
}

// so that shows in foreground
- (void)userNotificationCenter:(UNUserNotificationCenter*)center
       willPresentNotification:(UNNotification*)notification
         withCompletionHandler:
             (void (^)(UNNotificationPresentationOptions))completionHandler {
  UNNotificationPresentationOptions options =
      UNNotificationPresentationOptionSound |
      UNNotificationPresentationOptionBadge;
  if (@available(iOS 14.0, *)) {
    options |= UNNotificationPresentationOptionBanner;
  } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    options |= UNNotificationPresentationOptionAlert;
#pragma clang diagnostic pop
  }
  completionHandler(options);
}

- (void)openPushoverAppBuild {
  XUrl(@"https://pushover.net/apps/build");
}

- (void)openPushoverDashboard {
  XUrl(@"https://pushover.net/dashboard");
}

- (void)openPushbulletAccount {
  XUrl(@"https://www.pushbullet.com/#settings/account");
}

- (void)openIFTTTAccount {
  XUrl(@"https://ifttt.com/services/maker_webhooks/settings");
}

- (void)openDateFormatInstructions {
  XUrl(@"https://nsdateformatter.com");
}

- (void)openPusherReceiverFirefoxExtension {
  XUrl(@"https://addons.mozilla.org/en-US/firefox/addon/pusher-receiver/");
}

- (void)openPusherReceiverChromeExtension {
  XUrl(@"https://chrome.google.com/webstore/detail/pusher-receiver/"
       @"cegndpdokeeegijbkidfcolhomffhibh");
}

- (void)openTwitterBurkybang {
  [NSPusherManager.sharedController openTwitter:@"burkybang"];
}

@end
