#import "NSPServiceController.h"
#import "NSPCustomizeAppsController.h"
#import "NSPSharedSpecifiers.h"

#import "../global.h"
#import "../helpers.h"
#import <notify.h>

static int countAppIDsWithPrefix(NSDictionary *prefs, NSString *prefix) {
  int count = 0;
  for (id key in prefs.allKeys) {
    if (![key isKindOfClass:NSString.class]) {
      continue;
    }
    if ([key hasPrefix:prefix] && ((NSNumber *)prefs[key]).boolValue) {
      count += 1;
    }
  }
  return count;
}

@implementation NSPServiceController

- (id)initWithService:(NSString *)service
                image:(UIImage *)image
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
    UILabel *label = [UILabel new];
    label.text = _service;
    label.font = [UIFont boldSystemFontOfSize:17];

    UIImageView *imageView = [[UIImageView alloc] initWithImage:_image];

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
    NSArray *imgColors = [_colorCube extractColorsFromImage:_image flags:flags];
    if (!imgColors.count)
      return;
    _uiColor = [imgColors[0] copy];
  }

  // load each time to override NSPRootListController
  [NSPusherManager.sharedController setActiveTintColor:_uiColor];
  [self tintUIToPusherColor];
}

- (void)addObjectsFromArray:(NSArray *)source
                    atIndex:(int)idx
                    toArray:(NSMutableArray *)dest {
  for (id object in source) {
    [dest insertObject:object atIndex:idx];
    idx += 1;
  }
}

- (NSArray *)specifiers {
  if (!_specifiers) {
    NSMutableArray *allSpecifiers = nil;
    NSArray *sharedSpecifiers = nil;

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
    NSDictionary *prefs = @{};
    if (keyList) {
      prefs = (NSDictionary *)CFPreferencesCopyMultiple(
          keyList, PUSHER_APP_ID, kCFPreferencesCurrentUser,
          kCFPreferencesAnyHost);
      if (!prefs) {
        prefs = @{};
      }
      CFRelease(keyList);
    }

    for (PSSpecifier *specifier in allSpecifiers) {
      if (specifier.cellType == PSLinkCell) {
        if (XEq(specifier.name, @"App List")) {
          specifier.name = XStr(
              @"%@ (%d total)", specifier.name,
              countAppIDsWithPrefix(
                  prefs, [specifier propertyForKey:@"ALSettingsKeyPrefix"]));
          [specifier setProperty:self forKey:@"psListRef"];
        } else if (XEq(specifier.name, @"App Customization")) {
          NSString *prefsKey =
              _isCustom ? NSPPreferenceCustomServiceCustomAppsKey(_service)
                        : NSPPreferenceBuiltInServiceCustomAppsKey(_service);
          NSArray *customApps = (NSArray *)prefs[prefsKey];
          specifier.name = XStr(@"%@ (%d total)", specifier.name,
                                customApps ? (int)customApps.count : 0);
          [specifier setProperty:self forKey:@"psListRef"];
        }
      }
    }

    BOOL insertOnNext = NO;
    BOOL inserted = NO;
    int idx = 0;
    for (PSSpecifier *specifier in allSpecifiers) {
      if (insertOnNext && specifier.cellType == PSGroupCell) {
        [self addObjectsFromArray:sharedSpecifiers
                          atIndex:idx
                          toArray:allSpecifiers];
        inserted = YES;
        break;
      } else if (specifier.cellType == PSGroupCell &&
                 XEq(specifier.identifier,
                     @"Options")) { // insert at end of options group
        insertOnNext = YES;
      }
      idx += 1;
    }

    if (!inserted) {
      [allSpecifiers addObjectsFromArray:sharedSpecifiers];
    }

    NSArray *specialCells = @[ @(PSGroupCell), @(PSButtonCell), @(PSLinkCell) ];

    NSArray *globalSpecifiers =
        [self loadSpecifiersFromPlistName:@"GlobalAndServices" target:self];
    for (PSSpecifier *specifier in globalSpecifiers) {
      [specifier setProperty:_service forKey:@"service"];
      if (specifier.cellType == PSSegmentCell) {
        NSMutableArray *values = [specifier.values mutableCopy];
        NSMutableArray *titles = [NSMutableArray arrayWithObject:@"Default"];
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
        specifier->setter = @selector(setPreferenceValue:
                              forBuiltInServiceSpecifier:);
        specifier->getter = @selector(readBuiltInServicePreferenceValue:);
        [specifier setProperty:XStr(@"%@%@", _service,
                                    [specifier propertyForKey:@"key"])
                        forKey:@"key"];
      }
      specifier.target = NSPSharedSpecifiers.class;
    }
    [allSpecifiers addObjectsFromArray:globalSpecifiers];

    PSSpecifier *sendTestNotificationGroup = [PSSpecifier emptyGroupSpecifier];
    PSSpecifier *sendTestNotification =
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

- (void)sendTestNotification:(PSSpecifier *)specifier {
  [self.view endEditing:YES];

  XLog(@"Sending test for %@", _service);

  CPDistributedMessagingCenter *messagingCenter =
      [CPDistributedMessagingCenter centerNamed:PUSHER_MESSAGING_CENTER_NAME];

  // Two-way (wait for reply)
  NSDictionary *reply;
  reply = [messagingCenter
      sendMessageAndReceiveReplyName:PUSHER_TEST_PUSH_MESSAGE_NAME
                            userInfo:@{@"service" : _service}];

  if (reply[@"success"] && ((NSNumber *)reply[@"success"]).boolValue) {
    [self displayNotification:XStr(@"%@Sent", PUSHER_TEST_PUSH_RESULT_PREFIX)];
  } else {
    [self displayNotification:XStr(@"%@Failed to Send",
                                   PUSHER_TEST_PUSH_RESULT_PREFIX)];
  }
}

- (void)displayNotification:(NSString *)message {
  UNMutableNotificationContent *content = [UNMutableNotificationContent new];
  content.title = kName;
  content.body = message;

  UNNotificationRequest *request =
      [UNNotificationRequest requestWithIdentifier:@"TestNotificationResult"
                                           content:content
                                           trigger:nil];

  [UNUserNotificationCenter.currentNotificationCenter
      addNotificationRequest:request
       withCompletionHandler:^(NSError *error) {
         // XLog(@"addNotificationRequest error: %@", error.description);
         if (error) {
           UIAlertController *alert = XAlert(message);
           [alert addAction:XAlertBtn(@"Ok")];
           [self presentViewController:alert animated:YES completion:nil];
         }
       }];
}

// so that shows in foreground
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:
             (void (^)(UNNotificationPresentationOptions))completionHandler {
  completionHandler(UNNotificationPresentationOptionSound |
                    UNNotificationPresentationOptionBanner |
                    UNNotificationPresentationOptionBadge);
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
