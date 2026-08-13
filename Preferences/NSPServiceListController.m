#import "NSPServiceListController.h"
#import "NSPServiceController.h"
#import "NSPSharedSpecifiers.h"

@implementation NSPServiceListController

- (void)viewDidLoad {
  [super viewDidLoad];

  _lastTargetService = nil;
  _lastTargetIndexPath = nil;

  _loadedServiceControllers = [NSMutableDictionary new];

  CGRect tableFrame = self.view.bounds;
  if ([[UIDevice currentDevice] userInterfaceIdiom] ==
      UIUserInterfaceIdiomPad) {
    tableFrame = self.rootController.view.bounds;
  }
  _table = [[UITableView alloc] initWithFrame:tableFrame
                                        style:UITableViewStyleGrouped];
  [_table registerClass:UITableViewCell.class
      forCellReuseIdentifier:@"ServiceCell"];
  _table.dataSource = self;
  _table.delegate = self;
  _table.allowsSelectionDuringEditing = YES;
  [self.view addSubview:_table];
  _addNewServiceBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:@"Add"
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(addNewService)];

  self.navigationItem.title = @"Services";
  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:@"Edit"
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(toggleEditing:)];
  self.navigationItem.leftBarButtonItem = nil;
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  [NSPusherManager.sharedController setActiveTintColor:nil];
  [self tintUIToPusherColor];

  // Get preferences
  CFArrayRef keyList = CFPreferencesCopyKeyList(
      PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  _prefs = @{};
  if (keyList) {
    _prefs = (__bridge_transfer NSDictionary*)CFPreferencesCopyMultiple(
        keyList, PUSHER_APP_ID, kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost);
    if (!_prefs) {
      _prefs = @{};
    }
    CFRelease(keyList);
  }

  _sections = @[ @"Enabled", @"Disabled" ];
  _data =
      [@{@"Enabled" : [NSMutableArray new], @"Disabled" : [NSMutableArray new]}
          mutableCopy];
  _services = BUILTIN_PUSHER_SERVICES;
  _customServices = [(NSDictionary*)(_prefs[NSPPreferenceCustomServicesKey]
                                         ?: @{}) mutableCopy];

  _defaultImage = DEFAULT_IMAGE;
  _serviceImages = [NSMutableDictionary new];

  NSDictionary* builtInServices =
      (NSDictionary*)_prefs[NSPPreferenceBuiltInServicesKey] ?: @{};

  for (NSString* service in _services) {
    NSDictionary* serviceObj = builtInServices[service] ?: @{};
    if (serviceObj[NSPPreferenceServiceEnabledKey] &&
        ((NSNumber*)serviceObj[NSPPreferenceServiceEnabledKey]).boolValue) {
      [_data[@"Enabled"] addObject:service];
    } else {
      [_data[@"Disabled"] addObject:service];
    }
    _serviceImages[service] =
        [UIImage imageNamed:XStr(@"BuiltInService_%@", service)
                   inBundle:PUSHER_BUNDLE]
            ?: _defaultImage;
  }

  // make deep mutable and preload service images
  for (NSString* customService in _customServices.allKeys) {
    _customServices[customService] =
        [(_customServices[customService] ?: @{}) mutableCopy];
    if (_customServices[customService] &&
        _customServices[customService][@"Enabled"] &&
        ((NSNumber*)_customServices[customService][@"Enabled"]).boolValue) {
      [_data[@"Enabled"] addObject:customService];
    } else {
      [_data[@"Disabled"] addObject:customService];
    }
    _serviceImages[customService] =
        [UIImage imageNamed:XStr(@"CustomService_%@", customService)
                   inBundle:PUSHER_BUNDLE]
            ?: _defaultImage;
  }

  [_data[@"Enabled"]
      sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
  [_data[@"Disabled"]
      sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

  [_table reloadData];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (!_prefs[@"ServiceListTutorialShown"] ||
      !((NSNumber*)_prefs[@"ServiceListTutorialShown"]).boolValue) {
    [self showTutorial];
  }
}

- (void)showTutorial {
  UIWindow* window = nil;
  NSSet* scenes = [UIApplication sharedApplication].connectedScenes;
  for (UIScene* scene in scenes) {
    if (scene.activationState == UISceneActivationStateForegroundActive) {
      UIWindowScene* windowScene = (UIWindowScene*)scene;
      for (UIWindow* win in windowScene.windows) {
        if (win.isKeyWindow) {
          window = win;
          break;
        }
      }
      if (window != nil) {
        break;
      }
    }
  }
  // for (UIWindow *win in [UIApplication sharedApplication].windows) {
  //     if (win.isKeyWindow) {
  //         window = win;
  //         break;
  //     }
  // }
  // UIWindow *window = [UIApplication sharedApplication].keyWindow;
  UIView* tutorialView = [[UIView alloc] initWithFrame:window.bounds];
  tutorialView.alpha = 0.f;
  tutorialView.backgroundColor = [UIColor colorWithWhite:0.f alpha:0.9f];

  // Label setup
  UILabel* label = [UILabel new];
  label.font = [UIFont fontWithName:@"HelveticaNeue-Thin"
                               size:UIFont.systemFontSize * 1.5f];
  label.textColor = UIColor.whiteColor;
  label.text =
      @"After setting up your services, remember to enable them by using the "
      @"'Edit' button in the top right of this page and dragging your services "
      @"to the 'Enabled' section at the top.\n\nTap anywhere to continue.";
  label.lineBreakMode = NSLineBreakByWordWrapping;
  label.numberOfLines = 0;
  label.translatesAutoresizingMaskIntoConstraints = NO;
  label.textAlignment = NSTextAlignmentCenter;
  [tutorialView addSubview:label];

  // Constraints
  [label addConstraint:[NSLayoutConstraint
                           constraintWithItem:label
                                    attribute:NSLayoutAttributeWidth
                                    relatedBy:NSLayoutRelationEqual
                                       toItem:nil
                                    attribute:NSLayoutAttributeNotAnAttribute
                                   multiplier:1
                                     constant:270]];
  [label addConstraint:[NSLayoutConstraint
                           constraintWithItem:label
                                    attribute:NSLayoutAttributeHeight
                                    relatedBy:NSLayoutRelationEqual
                                       toItem:nil
                                    attribute:NSLayoutAttributeNotAnAttribute
                                   multiplier:1
                                     constant:tutorialView.frame.size.height]];
  [label.centerXAnchor constraintEqualToAnchor:label.superview.centerXAnchor]
      .active = YES;
  [label.centerYAnchor constraintEqualToAnchor:label.superview.centerYAnchor]
      .active = YES;

  [window addSubview:tutorialView];
  [UIView animateWithDuration:0.3
                   animations:^{
                     tutorialView.alpha = 1.f;
                   }];

  // Add touch action after a second
  UITapGestureRecognizer* tapGestureRecognizer = [[UITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(dismissTutorial:)];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.f * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   // Dismiss gesture
                   [tutorialView addGestureRecognizer:tapGestureRecognizer];
                 });

  CFStringRef tutorialKeyRef = CFSTR("ServiceListTutorialShown");
  [NSPSharedSpecifiers setPreference:tutorialKeyRef
                               value:(__bridge CFNumberRef) @YES
                        shouldNotify:NO];
  CFRelease(tutorialKeyRef);
  NSMutableDictionary* mutablePrefs = [_prefs mutableCopy];
  mutablePrefs[@"ServiceListTutorialShown"] = @YES;
  _prefs = [mutablePrefs copy];
}

- (void)dismissTutorial:(UITapGestureRecognizer*)tapGestureRecognizer {
  UIView* tutorialView = tapGestureRecognizer.view;
  [UIView animateWithDuration:0.3
      animations:^{
        tutorialView.alpha = 0.f;
      }
      completion:^(BOOL finished) {
        [tutorialView removeFromSuperview];
      }];
}

- (void)toggleEditing:(UIBarButtonItem*)barButtonItem {
  [_table setEditing:![_table isEditing] animated:YES];
  barButtonItem.title = [_table isEditing] ? @"Done" : @"Edit";
  self.navigationItem.leftBarButtonItem =
      [_table isEditing] ? _addNewServiceBarButtonItem : nil;
  if (![_table isEditing]) {
    // Save
    NSMutableDictionary* builtInServices = [(
        [NSPSharedSpecifiers
            getPreference:(__bridge CFStringRef)NSPPreferenceBuiltInServicesKey]
            ?: @{}) mutableCopy];
    for (NSString* service in _services) {
      NSMutableDictionary* serviceObj =
          [(builtInServices[service] ?: @{}) mutableCopy];
      serviceObj[NSPPreferenceServiceEnabledKey] =
          @([_data[@"Enabled"] containsObject:service]);
      builtInServices[service] = serviceObj;
    }
    [NSPSharedSpecifiers
        setPreference:(__bridge CFStringRef)NSPPreferenceBuiltInServicesKey
                value:(__bridge CFPropertyListRef)builtInServices
         shouldNotify:NO];
    for (NSString* customService in _customServices.allKeys) {
      NSNumber* customServiceEnabled =
          @([_data[@"Enabled"] containsObject:customService]);
      if (!_customServices[customService]) {
        _customServices[customService] =
            [@{@"Enabled" : customServiceEnabled} mutableCopy];
      } else {
        _customServices[customService][@"Enabled"] = customServiceEnabled;
      }
    }
    [self saveCustomServices]; // will notify post
                               // notify_post(PUSHER_PREFS_NOTIFICATION);
  }
}

- (void)addNewService {
  __unsafe_unretained NSPServiceListController* weakSelf = self;
  UIAlertController* alert = XAlertTitle(@"Add Custom Service", nil);
  __unsafe_unretained UIAlertController* weakAlert = alert;
  [alert addTextFieldWithConfigurationHandler:^(UITextField* textField) {
    textField.placeholder = @"Service Name";
  }];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  id handler = ^(UIAlertAction* action) {
    if (!weakAlert || !weakAlert.textFields ||
        ![weakAlert.textFields isKindOfClass:NSArray.class]) {
      XLog(@"alert or alert.textFields nil: %@ %@", weakAlert,
           weakAlert ? weakAlert.textFields : nil);
      return;
    }
    if (weakAlert.textFields.count == 0) {
      XLog(@"No text fields found");
      return;
    }
    UITextField* textField = weakAlert.textFields[0];
    if (!textField || !textField.text ||
        ![textField.text isKindOfClass:NSString.class]) {
      XLog(@"textField or textField.text nil: %@ %@", textField,
           textField ? textField.text : nil);
      return;
    }
    NSString* newServiceName = [textField.text
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if (newServiceName.length < 1) {
      XLog(@"newServiceName empty");
      return;
    }
    if ([weakSelf->_customServices.allKeys containsObject:newServiceName] ||
        [weakSelf->_services containsObject:newServiceName]) {
      // Nested block: also uses weakSelf, not self.
      id existsHandler = ^(UIAlertAction* existsAction) {
        [weakSelf addNewService];
      };
      UIAlertController* existsAlert =
          XAlertTitle(@"Error", @"A service with that name already exists.");
      [existsAlert addAction:XAlertBtnHandler(@"Ok", existsHandler)];
      [weakSelf presentViewController:existsAlert animated:YES
                           completion:nil];
      XLog(@"newServiceName already exists");
      return;
    }
    weakSelf->_customServices[newServiceName] = [@{@"Enabled" : @NO} mutableCopy];
    [weakSelf->_data[@"Disabled"] addObject:newServiceName];
    [weakSelf->_data[@"Disabled"]
        sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    UIImage* defaultImage = weakSelf->_defaultImage;
    if (!defaultImage || ![defaultImage isKindOfClass:UIImage.class]) {
      defaultImage = DEFAULT_IMAGE;
    }

    NSString* imageName = XStr(@"CustomService_%@", newServiceName);
    weakSelf->_serviceImages[newServiceName] =
        [UIImage imageNamed:imageName inBundle:PUSHER_BUNDLE] ?: defaultImage;
    [weakSelf->_table reloadSections:[NSIndexSet indexSetWithIndex:1]
                    withRowAnimation:UITableViewRowAnimationAutomatic];
    [weakSelf saveCustomServices];
  };
  [alert addAction:XAlertBtnHandler(@"Add", handler)];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveCustomServices {
  [NSPSharedSpecifiers
      setPreference:(__bridge CFStringRef)NSPPreferenceCustomServicesKey
              value:(__bridge CFPropertyListRef)_customServices
       shouldNotify:YES];
}

- (void)tableView:(UITableView*)table
    didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [table deselectRowAtIndexPath:indexPath animated:YES];
  NSString* currService = _data[_sections[indexPath.section]][indexPath.row];
  BOOL isCustomService = [_customServices.allKeys containsObject:currService];
  if (table.editing) {
    if (isCustomService) {
      // Rename
      [self renameService:currService];
    }
  } else {
    NSPServiceController* controller;
    if ([_loadedServiceControllers.allKeys containsObject:currService]) {
      controller = _loadedServiceControllers[currService];
    } else {
      controller = [[NSPServiceController alloc]
          initWithService:currService
                    image:_serviceImages[currService]
                 isCustom:isCustomService];
      _loadedServiceControllers[currService] = controller;
    }
    [self pushController:controller];
  }
}

- (NSInteger)tableView:(UITableView*)table
    numberOfRowsInSection:(NSInteger)section {
  return ((NSArray*)_data[_sections[section]]).count;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)table {
  return _sections.count;
}

- (NSString*)tableView:(UITableView*)tableView
    titleForHeaderInSection:(NSInteger)section {
  return _sections[section];
}

- (BOOL)tableView:(UITableView*)tableView
    shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath*)indexPath {
  return NO;
}

- (UITableViewCell*)tableView:(UITableView*)table
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell =
      [table dequeueReusableCellWithIdentifier:@"ServiceCell"
                                  forIndexPath:indexPath];
  NSString* service = _data[_sections[indexPath.section]][indexPath.row];
  cell.textLabel.text = service;
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  cell.imageView.image = _serviceImages[service];
  return cell;
}

- (BOOL)tableView:(UITableView*)table
    canMoveRowAtIndexPath:(NSIndexPath*)indexPath {
  return YES;
}

- (void)tableView:(UITableView*)table
    moveRowAtIndexPath:(NSIndexPath*)sourceIndexPath
           toIndexPath:(NSIndexPath*)destinationIndexPath {
  _lastTargetService = nil;
  _lastTargetIndexPath = nil;
  NSString* service =
      _data[_sections[sourceIndexPath.section]][sourceIndexPath.row];
  [_data[_sections[sourceIndexPath.section]]
      removeObjectAtIndex:sourceIndexPath.row];
  [_data[_sections[destinationIndexPath.section]]
      insertObject:service
           atIndex:destinationIndexPath.row];
}

- (UITableViewCellEditingStyle)tableView:(UITableView*)table
           editingStyleForRowAtIndexPath:(NSIndexPath*)indexPath {
  NSString* service = _data[_sections[indexPath.section]][indexPath.row];
  if ([_customServices.allKeys containsObject:service]) {
    return UITableViewCellEditingStyleDelete;
  }
  return UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView*)table
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath*)indexPath {
  NSString* service = _data[_sections[indexPath.section]][indexPath.row];
  if (editingStyle == UITableViewCellEditingStyleDelete &&
      [_customServices.allKeys containsObject:service]) {
    [_customServices removeObjectForKey:service];
    [_data[_sections[indexPath.section]] removeObjectAtIndex:indexPath.row];
    // Drop cached controller and image so a recreated service of the same
    // name doesn't reuse stale data.
    [_loadedServiceControllers removeObjectForKey:service];
    [_serviceImages removeObjectForKey:service];
    [self saveCustomServices];

    // Also remove the service's flat pref keys (app list / custom apps) so a
    // recreated service of the same name doesn't resurrect old data.
    NSString* blPrefix = NSPPreferenceCustomServiceBLPrefix(service);
    NSString* customAppsKey =
        NSPPreferenceCustomServiceCustomAppsKey(service);
    NSMutableDictionary* newPrefs = [_prefs mutableCopy];
    NSMutableArray* keysToRemove = [NSMutableArray new];
    for (NSString* key in _prefs.allKeys) {
      if ([key hasPrefix:blPrefix]) {
        [keysToRemove addObject:key];
        [newPrefs removeObjectForKey:key];
      }
    }
    if (newPrefs[customAppsKey]) {
      [keysToRemove addObject:customAppsKey];
      [newPrefs removeObjectForKey:customAppsKey];
    }
    if (keysToRemove.count) {
      CFPreferencesSetMultiple(
          (__bridge CFDictionaryRef)newPrefs, (__bridge CFArrayRef)keysToRemove,
          PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
      CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                               kCFPreferencesAnyHost);
      notify_post(PUSHER_PREFS_NOTIFICATION);
      _prefs = [newPrefs copy];
    }

    [table deleteRowsAtIndexPaths:@[ indexPath ]
                 withRowAnimation:UITableViewRowAnimationLeft];
  }
}

- (NSIndexPath*)tableView:(UITableView*)tableView
    targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath*)sourceIndexPath
                         toProposedIndexPath:
                             (NSIndexPath*)proposedDestinationIndexPath {
  if (sourceIndexPath.section == proposedDestinationIndexPath.section) {
    return sourceIndexPath;
  }
  NSString* service =
      _data[_sections[sourceIndexPath.section]][sourceIndexPath.row];
  if (_lastTargetService && XEq(service, _lastTargetService)) {
    return _lastTargetIndexPath;
  }
  _lastTargetService = service;
  NSArray* tempArray =
      [[_data
        [_sections
         [proposedDestinationIndexPath
              .section]] arrayByAddingObject : service] sortedArrayUsingSelector :
       @selector(localizedCaseInsensitiveCompare:)];
  _lastTargetIndexPath =
      [NSIndexPath indexPathForRow:[tempArray indexOfObject:service]
                         inSection:proposedDestinationIndexPath.section];
  return _lastTargetIndexPath;
}

- (void)renameService:(NSString*)currService {

  __unsafe_unretained NSPServiceListController* weakSelf = self;
  UIAlertController* alert = XAlertTitle(XStr(@"Rename %@", currService), nil);
  __unsafe_unretained UIAlertController* weakAlert = alert;
  [alert addTextFieldWithConfigurationHandler:^(UITextField* textField) {
    textField.placeholder = @"Service Name";
    textField.text = currService;
  }];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  id handler = ^(UIAlertAction* action) {
    UITextField* textField = weakAlert.textFields[0];
    if (!textField || !textField.text) {
      return;
    }
    NSString* newServiceName = [textField.text
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if (newServiceName.length < 1 || XEq(newServiceName, currService)) {
      return;
    }
    if ([weakSelf->_customServices.allKeys containsObject:newServiceName] ||
        [weakSelf->_services containsObject:newServiceName]) {
      // Nested block: uses weakSelf, not self.
      id existsHandler = ^(UIAlertAction* existsAction) {
        [weakSelf renameService:currService];
      };
      UIAlertController* existsAlert =
          XAlertTitle(XStr(@"Rename %@", currService),
                      @"A service with that name already exists.");
      [existsAlert addAction:XAlertBtnHandler(@"Ok", existsHandler)];
      [weakSelf presentViewController:existsAlert animated:YES completion:nil];
      return;
    }

    weakSelf->_serviceImages[newServiceName] =
        weakSelf->_serviceImages[currService];
    [weakSelf->_serviceImages removeObjectForKey:currService];

    weakSelf->_customServices[newServiceName] =
        [weakSelf->_customServices[currService] mutableCopy];
    [weakSelf->_customServices removeObjectForKey:currService];
    [weakSelf saveCustomServices];

    // Drop any cached service controller for the old name so the renamed
    // service reloads with fresh data instead of reusing the stale instance.
    [weakSelf->_loadedServiceControllers removeObjectForKey:currService];

    // Get preferences
    CFArrayRef keyList = CFPreferencesCopyKeyList(
        PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    NSMutableDictionary* newPrefs = nil;
    if (keyList) {
      NSDictionary* copiedPrefs =
          (__bridge_transfer NSDictionary*)CFPreferencesCopyMultiple(
              keyList, PUSHER_APP_ID, kCFPreferencesCurrentUser,
              kCFPreferencesAnyHost);
      newPrefs = [copiedPrefs mutableCopy];
      if (!newPrefs) {
        newPrefs = [NSMutableDictionary new];
      }
      CFRelease(keyList);
    } else {
      newPrefs = [NSMutableDictionary new];
    }

    NSDictionary* keysToMigrate = @{
      NSPPreferenceCustomServiceCustomAppsKey(currService) :
          NSPPreferenceCustomServiceCustomAppsKey(newServiceName)
    };

    NSDictionary* prefixesToMigrate = @{
      NSPPreferenceCustomServiceBLPrefix(currService) :
          NSPPreferenceCustomServiceBLPrefix(newServiceName)
    };

    NSMutableArray* keysToRemove =
        [NSMutableArray arrayWithArray:keysToMigrate.allKeys];

    for (NSString* oldKey in keysToMigrate.allKeys) {
      NSString* newKey = keysToMigrate[oldKey];
      newPrefs[newKey] = [newPrefs[oldKey] copy];
      [newPrefs removeObjectForKey:oldKey];
    }

    for (NSString* oldPrefix in prefixesToMigrate.allKeys) {
      NSString* newPrefix = prefixesToMigrate[oldPrefix];
      NSMutableArray* foundPrefixKeys = [NSMutableArray new];
      for (id key in newPrefs.allKeys) {
        if (![key isKindOfClass:NSString.class]) {
          continue;
        }
        if ([key hasPrefix:oldPrefix]) {
          [foundPrefixKeys addObject:key];
        }
      }
      for (NSString* oldKey in foundPrefixKeys) {
        NSString* newKey =
            [oldKey stringByReplacingOccurrencesOfString:oldPrefix
                                              withString:newPrefix];
        newPrefs[newKey] = [newPrefs[oldKey] copy];
        [newPrefs removeObjectForKey:oldKey];
        [keysToRemove addObject:oldKey];
      }
    }

    CFPreferencesSetMultiple((__bridge CFDictionaryRef)newPrefs,
                             (__bridge CFArrayRef)keysToRemove, PUSHER_APP_ID,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    notify_post(PUSHER_PREFS_NOTIFICATION);

    NSString* currSection =
        ((NSNumber*)weakSelf->_customServices[newServiceName][@"Enabled"])
            .boolValue
            ? @"Enabled"
            : @"Disabled";
    [weakSelf->_data[currSection] removeObject:currService];
    [weakSelf->_data[currSection] addObject:newServiceName];
    [weakSelf->_data[currSection]
        sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    [weakSelf->_table reloadSections:
                          [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]
                    withRowAnimation:UITableViewRowAnimationFade];
  };
  [alert addAction:XAlertBtnHandler(@"Rename", handler)];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)scrollViewWillBeginDragging:(UIScrollView*)scrollView {
  [self.view endEditing:YES];
}

@end
