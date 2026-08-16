#import "NSPLogController.h"
#import "NSPLocalization.h"
#import "NSPAppSelectionController.h"
#import "NSPLogFormatter.h"
#import "UIImageIcon.h"
#import "NSPusherManager.h"
#import "../Shared/NSPushLogStore.h"
#import "../Shared/NSPushPrefsStore.h"
#import <MobileCoreServices/LSApplicationProxy.h>

#define SEGMENTED_CONTROL_TAG 673
#define NETWORK_RESPONSE_ITEMS @[ @"Any", @"Success", @"No Data", @"Error" ]
#define EXPANDED_TEXT_VIEW_TAG 674

static __weak NSPLogController* logControllerSharedInstance = nil;
static void logsUpdated() {
  // Darwin notification callbacks run on a background thread; UITableView must
  // only be touched on the main thread. Keep the guards: the static does not
  // retain the controller, so it may have been deallocated by the time the
  // block runs.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (logControllerSharedInstance &&
        [logControllerSharedInstance isKindOfClass:NSPLogController.class] &&
        [logControllerSharedInstance
            respondsToSelector:@selector(updateLogAndReload)]) {
      [logControllerSharedInstance updateLogAndReload];
    }
  });
}

@implementation NSPLogController

- (void)dealloc {
  // Remove the Darwin observer before anything else so a notification can't
  // fire into a half-torn-down object.
  CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                     NULL, CFSTR(PUSHER_LOG_PREFS_NOTIFICATION),
                                     NULL);
  // Only clear the shared instance if this controller is still the current
  // one; an older instance being torn down after a newer one was created must
  // not disable live log updates for the newer controller.
  if (logControllerSharedInstance == self) {
    logControllerSharedInstance = nil;
  }
}

- (void)showAppFilterTutorial {
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
  // UIWindow *window = [UIApplication sharedApplication].keyWindow;
  UIView* tutorialView = [[UIView alloc] initWithFrame:window.bounds];
  tutorialView.alpha = 0.f;
  tutorialView.backgroundColor = [UIColor colorWithWhite:0.f alpha:0.9f];

  // Label setup
  UILabel* label = [UILabel new];
  label.font = [UIFont fontWithName:@"HelveticaNeue-Thin"
                               size:UIFont.systemFontSize * 1.5f];
  label.textColor = UIColor.whiteColor;
  label.text = NSPLocalizedString(@"After using the app filter, you can swipe to delete to unset "
                                          @"it and show all apps again.\n\nTap on any truncated log to "
                                          @"expand it.\n\n Tap and hold on a log to copy it to the "
                                          @"clipboard.\n\nTap anywhere to continue.", nil);
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

  [NSPushPrefsStore setPreferenceValue:@YES
                                forKey:@"LogAppFilterTutorialShown"
                          shouldNotify:NO];
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

- (void)viewDidLoad {
  [super viewDidLoad];

  logControllerSharedInstance = self;
  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                  NULL, (CFNotificationCallback)logsUpdated,
                                  CFSTR(PUSHER_LOG_PREFS_NOTIFICATION), NULL,
                                  CFNotificationSuspensionBehaviorCoalesce);

  // _appList = [ALApplicationList sharedApplicationList];

  CGRect tableFrame = self.view.bounds;
  if ([[UIDevice currentDevice] userInterfaceIdiom] ==
      UIUserInterfaceIdiomPad) {
    tableFrame = self.rootController.view.bounds;
  }
  _table = [[UITableView alloc] initWithFrame:tableFrame
                                        style:UITableViewStyleGrouped];
  [_table registerClass:UITableViewCell.class
      forCellReuseIdentifier:@"LogCell"];
  _table.delegate = self;
  _table.dataSource = self;
  [self.view addSubview:_table];

  _service = [self.specifier propertyForKey:@"service"] ?: @"";
  _global = XIsEmpty(_service);
  _logKey = XStr(@"%@Log", _service);
  _logEnabledKey = XStr(@"%@LogEnabled", _service);
  _filteredEndResult = nil;
  _filteredNetworkResponse = nil;
  _filteredAppID = nil;
  _filteredGlobalOnly = NO;

  self.navigationItem.title =
      [self.specifier propertyForKey:@"label"] ?: NSPLocalizedString(@"Log", nil);

  _logEnabled = NSPushBoolResolved(
      [NSPushPrefsStore preferenceValueForKey:_logEnabledKey], YES);

  [self updateLogAndReload];
}

- (void)updateLogEnabled:(UISwitch*)logEnabledSwitch {
  _logEnabled = logEnabledSwitch.isOn;
  [NSPushPrefsStore setPreferenceValue:@(_logEnabled)
                                forKey:_logEnabledKey
                          shouldNotify:YES];
}

- (void)updateGlobalOnly:(UISwitch*)globalOnlySwitch {
  _filteredGlobalOnly = globalOnlySwitch.isOn;
  [self updateLogAndReload];
}

- (void)updateLogAndReload {
  [self updateLog];
  [_table reloadData];
}

- (void)updateLog {
  NSDictionary* prefs = [NSPushLogStore snapshot];

  _truncatedIndexPaths = [NSMutableArray new];

  _sections = [@[ @"Settings", @"Filters" ] mutableCopy];

  _data = [@{
    _sections[0] : [@[ @"Logger Enabled", @"Clear All Logs" ] mutableCopy],
    _sections[1] : [@[
      @"Network Response", @"End Result", @"Select an App", @"Global Only"
    ] mutableCopy]
  } mutableCopy];

  if (_global) {
    // remove enabled switch because global can't be disabled
    [_data[_sections[0]] removeObject:@"Logger Enabled"];
    _logEnabledSwitchRow = -1;
    _clearLogRow = 0;

    _globalOnlyRow = 3;
  } else {
    _logEnabledSwitchRow = 0;
    _clearLogRow = 1;
    // remove global only switch because don't show on individual services
    [_data[_sections[1]] removeObject:@"Global Only"];
    _globalOnlyRow = -1;
  }

  _settingsSection = 0;
  _filterSection = 1;
  _networkResponseRow = 0;
  _endResultFilterRow = 1;
  _appFilterRow = 2;
  // _globalOnlyRow above in _gloabl check

  _firstLogSection = _data.count;
  _expandedIndexPaths = [NSMutableArray new];

  NSArray* prefsLog = nil;
  if (_global && !_filteredGlobalOnly) {
    NSMutableArray* allLogs = [NSMutableArray new];
    for (id key in prefs.allKeys) {
      if (![key isKindOfClass:NSString.class]) {
        continue;
      }
      // should be all but just in case change implementation later
      if ([key hasSuffix:@"Log"]) {
        NSString* service = [key substringToIndex:((NSString*)key).length - 3];
        id rawServiceLogs = prefs[key];
        if (![rawServiceLogs isKindOfClass:NSArray.class]) {
          continue;
        }
        for (id rawLogSection in (NSArray*)rawServiceLogs) {
          if (![rawLogSection isKindOfClass:NSDictionary.class]) {
            continue;
          }
          NSMutableDictionary* newLogSection =
              [(NSDictionary*)rawLogSection mutableCopy];
          newLogSection[@"service"] = service;
          [allLogs addObject:newLogSection];
        }
      }
    }
    prefsLog = allLogs;
  } else {
    // handles _filteredGlobalOnly because _logKey set to @"Log" which is just
    // global
    id rawPrefsLog = prefs[_logKey];
    prefsLog = [rawPrefsLog isKindOfClass:NSArray.class] ? rawPrefsLog : @[];
  }

  // sort prefs log by timestamp
  NSSortDescriptor* timestampDescriptor =
      [[NSSortDescriptor alloc] initWithKey:@"timestamp" ascending:NO];
  prefsLog = [prefsLog sortedArrayUsingDescriptors:@[ timestampDescriptor ]];

  for (id rawLogSection in prefsLog) {
    if (![rawLogSection isKindOfClass:NSDictionary.class]) {
      continue;
    }
    NSDictionary* logSection = (NSDictionary*)rawLogSection;
    NSString* logSectionAppID = nil;
    if ([logSection[@"appID"] isKindOfClass:NSString.class]) {
      logSectionAppID = (NSString*)logSection[@"appID"];
    }
    // if app filter is on, skip if not same app
    if (_filteredAppID) {
      if (!logSectionAppID || !XEq(logSectionAppID, _filteredAppID)) {
        continue;
      }
    }

    NSString* sectionName = [NSPLogFormatter sectionTitleForLogSection:logSection];
    id rawLogs = logSection[@"logs"];
    NSArray* sourceLogs = [rawLogs isKindOfClass:NSArray.class] ? rawLogs : @[];
    NSMutableArray* logs = [NSMutableArray new];
    for (id log in sourceLogs) {
      if ([log isKindOfClass:NSString.class]) {
        [logs addObject:log];
      } else if (log) {
        [logs addObject:[log description]];
      }
    }

    if (![NSPLogFormatter
            shouldIncludeLogs:logs
             networkResponse:_filteredNetworkResponse
                   endResult:_filteredEndResult]) {
      continue;
    }
    [_sections addObject:sectionName];
    _data[sectionName] = logs;
  }
}

- (BOOL)tableView:(UITableView*)tableView
    shouldHighlightRowAtIndexPath:(NSIndexPath*)indexPath {
  return (indexPath.section == _settingsSection &&
          indexPath.row == _clearLogRow) ||
         (indexPath.section == _filterSection &&
          indexPath.row == _appFilterRow);
}

- (BOOL)tableView:(UITableView*)tableView
    canEditRowAtIndexPath:(NSIndexPath*)indexPath {
  return indexPath.section == _filterSection && indexPath.row == _appFilterRow;
}

- (void)tableView:(UITableView*)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath*)indexPath {
  if (indexPath.section == _filterSection && indexPath.row == _appFilterRow &&
      editingStyle == UITableViewCellEditingStyleDelete) {
    _filteredAppID = nil;
    [self updateLogAndReload];
  }
}

- (void)tableView:(UITableView*)tableView
    didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];

  // Clear log button
  if (indexPath.section == 0 && indexPath.row == _clearLogRow) {
    if (_global) {
      [NSPushLogStore removeAllLogs];
    } else {
      [NSPushLogStore removeLogsForService:_service];
    }

    // Logs are cleared above; simply rebuild the sections and reload. The old
    // code recomputed a deleteSections range from the pre-clear section count
    // after _sections had already been rebuilt, which crashed with
    // NSInternalInconsistencyException whenever any log existed.
    [self updateLog];
    [_table reloadData];
  } else if (indexPath.section == _filterSection &&
             indexPath.row == _appFilterRow) {
    // app filter
    NSPAppSelectionController* appSelectionController =
        [NSPAppSelectionController new];
    [appSelectionController setCallback:^(id appID) {
      _filteredAppID = [appID copy];
      [self updateLogAndReload];
      BOOL tutorialShown = NSPushBoolResolved(
          [NSPushPrefsStore preferenceValueForKey:@"LogAppFilterTutorialShown"],
          NO);
      if (!tutorialShown) {
        [self showAppFilterTutorial];
      }
    }];
    // appSelectionController.navItemTitle = @"Select an App";
    // appSelectionController.selectingMultiple = NO;
    if (_filteredAppID) {
      appSelectionController.selectedAppID = _filteredAppID;
      // appSelectionController.selectedAppIDs = [@[ _filteredAppID ]
      // mutableCopy];
    }
    appSelectionController.useSearchBar = YES;
    [self.navigationController pushViewController:appSelectionController
                                         animated:YES];
  }
}

- (BOOL)tableView:(UITableView*)tableView
    shouldShowMenuForRowAtIndexPath:(NSIndexPath*)indexPath {
  return indexPath.section >= _firstLogSection;
}

- (BOOL)tableView:(UITableView*)tableView
     canPerformAction:(SEL)action
    forRowAtIndexPath:(NSIndexPath*)indexPath
           withSender:(id)sender {
  return indexPath.section >= _firstLogSection && action == @selector(copy:);
}

- (void)tableView:(UITableView*)tableView
        performAction:(SEL)action
    forRowAtIndexPath:(NSIndexPath*)indexPath
           withSender:(id)sender {
  if (indexPath.section < _firstLogSection || action != @selector(copy:)) {
    return;
  }
  // use this instead of cell.textLabel.text because may be expanded and have
  // text in uitextview not label
  UIPasteboard.generalPasteboard.string =
      _data[_sections[indexPath.section]][indexPath.row];
}

- (NSString*)tableView:(UITableView*)tableView
    titleForHeaderInSection:(NSInteger)section {
  NSString* title = _sections[section];
  if (section < _firstLogSection) {
    return NSPLocalizedString(title, nil);
  }
  return title;
}

- (NSInteger)tableView:(UITableView*)tableView
    numberOfRowsInSection:(NSInteger)section {
  return ((NSArray*)_data[_sections[section]]).count;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return _sections.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell =
      [tableView dequeueReusableCellWithIdentifier:@"LogCell"
                                      forIndexPath:indexPath];

  cell.accessoryType = UITableViewCellAccessoryNone;
  cell.accessoryView = nil;
  cell.imageView.image = nil;
  // cell.textLabel.numberOfLines = 1;
  // cell.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
  cell.textLabel.text = nil;
  cell.textLabel.textColor = nil;
  cell.tintColor = NSPusherManager.sharedController.activeTintColor;

  UITextView* expandedTextView =
      [cell.contentView viewWithTag:EXPANDED_TEXT_VIEW_TAG];
  if (expandedTextView) {
    [expandedTextView removeFromSuperview];
  }

  UIView* segmentedControlView =
      [cell.contentView viewWithTag:SEGMENTED_CONTROL_TAG];
  if (segmentedControlView) {
    [segmentedControlView removeFromSuperview];
  }

  if (indexPath.section != _filterSection ||
      (indexPath.row != _networkResponseRow &&
       indexPath.row != _endResultFilterRow)) {
    NSString* rowTitle = _data[_sections[indexPath.section]][indexPath.row];
    if (indexPath.section < _firstLogSection) {
      rowTitle = NSPLocalizedString(rowTitle, nil);
    }
    cell.textLabel.text = rowTitle;
  }

  if (indexPath.section == _filterSection) {
    if (indexPath.row == _networkResponseRow ||
        indexPath.row == _endResultFilterRow) {
      BOOL isNetworkResponse = indexPath.row == _networkResponseRow;
      UISegmentedControl* segmentedControl = nil;
      if (isNetworkResponse) {
        NSArray* localizedNetworkItems = @[
          NSPLocalizedString(@"Any", nil), NSPLocalizedString(@"Success", nil),
          NSPLocalizedString(@"No Data", nil), NSPLocalizedString(@"Error", nil)
        ];
        segmentedControl =
            [[UISegmentedControl alloc] initWithItems:localizedNetworkItems];
        segmentedControl.selectedSegmentIndex =
            _filteredNetworkResponse
                ? [NETWORK_RESPONSE_ITEMS
                      indexOfObject:_filteredNetworkResponse]
                : 0;
        [segmentedControl addTarget:self
                             action:@selector(networkResponseFilterUpdated:)
                   forControlEvents:UIControlEventValueChanged];
      } else {
        NSArray* localizedEndResultItems = @[
          NSPLocalizedString(@"Any", nil), NSPLocalizedString(@"Blocked", nil),
          NSPLocalizedString(@"Pushed", nil)
        ];
        segmentedControl =
            [[UISegmentedControl alloc] initWithItems:localizedEndResultItems];
        segmentedControl.selectedSegmentIndex =
            _filteredEndResult
                ? [END_RESULT_ITEMS indexOfObject:_filteredEndResult]
                : 0;
        [segmentedControl addTarget:self
                             action:@selector(endResultFilterUpdated:)
                   forControlEvents:UIControlEventValueChanged];
      }
      segmentedControl.tag = SEGMENTED_CONTROL_TAG;
      segmentedControl.apportionsSegmentWidthsByContent = NO;
      [cell.contentView addSubview:segmentedControl];

      segmentedControl.translatesAutoresizingMaskIntoConstraints = NO;
      [segmentedControl.topAnchor
          constraintEqualToAnchor:segmentedControl.superview.topAnchor
                         constant:5]
          .active = YES;
      [segmentedControl.bottomAnchor
          constraintEqualToAnchor:segmentedControl.superview.bottomAnchor
                         constant:-5]
          .active = YES;
      [segmentedControl.leadingAnchor
          constraintEqualToAnchor:segmentedControl.superview.leadingAnchor
                         constant:5]
          .active = YES;
      [segmentedControl.trailingAnchor
          constraintEqualToAnchor:segmentedControl.superview.trailingAnchor
                         constant:-5]
          .active = YES;
      [segmentedControl.centerXAnchor
          constraintEqualToAnchor:segmentedControl.superview.centerXAnchor]
          .active = YES;
      [segmentedControl.centerYAnchor
          constraintEqualToAnchor:segmentedControl.superview.centerYAnchor]
          .active = YES;
    } else if (indexPath.row == _appFilterRow) {
      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
      if (_filteredAppID) {
        LSApplicationProxy* appProxy =
            [LSApplicationProxy applicationProxyForIdentifier:_filteredAppID];
        NSString* appName = [appProxy localizedName]
                                ?: NSPLocalizedString(@"Unknown App", nil);
        cell.textLabel.text = XStr(NSPLocalizedString(@"App Filter: %@", nil), appName);
        cell.imageView.image = [UIImage
            _applicationIconImageForBundleIdentifier:_filteredAppID
                                              format:0
                                               scale:[UIScreen mainScreen]
                                                         .scale];
        // cell.imageView.image = [_appList
        // iconOfSize:ALApplicationIconSizeSmall
        //                        forDisplayIdentifier:_filteredAppID];
      }
    } else if (indexPath.row == _globalOnlyRow) {
      UISwitch* globalOnlySwitch = [UISwitch new];
      globalOnlySwitch.on = _filteredGlobalOnly;
      [globalOnlySwitch addTarget:self
                           action:@selector(updateGlobalOnly:)
                 forControlEvents:UIControlEventValueChanged];
      cell.accessoryView = globalOnlySwitch;
    }

    return cell;
  }

  BOOL expanded = [_expandedIndexPaths containsObject:indexPath];
  if (expanded) {
    // cell.textLabel.numberOfLines = 0;
    // cell.textLabel.lineBreakMode = NSLineBreakByWordWrapping;
    expandedTextView = [UITextView new];
    expandedTextView.tag = EXPANDED_TEXT_VIEW_TAG;
    expandedTextView.editable = NO;
    expandedTextView.text = cell.textLabel.text;
    expandedTextView.font = cell.textLabel.font;
    cell.textLabel.text = nil;
    [cell.contentView addSubview:expandedTextView];

    CGFloat textSizeHeight =
        [expandedTextView.text
            boundingRectWithSize:CGSizeMake(cell.contentView.bounds.size.width,
                                            MAXFLOAT)
                         options:NSStringDrawingUsesLineFragmentOrigin
                      attributes:@{NSFontAttributeName : expandedTextView.font}
                         context:nil]
            .size.height +
        30.0;
    CGFloat maxHeight = UIScreen.mainScreen.bounds.size.height / 2;
    CGFloat height = textSizeHeight > maxHeight ? maxHeight : textSizeHeight;

    expandedTextView.translatesAutoresizingMaskIntoConstraints = NO;
    [expandedTextView.topAnchor
        constraintEqualToAnchor:expandedTextView.superview.topAnchor
                       constant:10]
        .active = YES;
    [expandedTextView.bottomAnchor
        constraintEqualToAnchor:expandedTextView.superview.bottomAnchor
                       constant:-10]
        .active = YES;
    [expandedTextView.leadingAnchor
        constraintEqualToAnchor:expandedTextView.superview.leadingAnchor
                       constant:10]
        .active = YES;
    [expandedTextView.trailingAnchor
        constraintEqualToAnchor:expandedTextView.superview.trailingAnchor
                       constant:-10]
        .active = YES;
    [expandedTextView
        addConstraint:[NSLayoutConstraint
                          constraintWithItem:expandedTextView
                                   attribute:NSLayoutAttributeHeight
                                   relatedBy:NSLayoutRelationEqual
                                      toItem:nil
                                   attribute:NSLayoutAttributeNotAnAttribute
                                  multiplier:1
                                    constant:height]];
  }

  if (indexPath.section >= _firstLogSection) {
    if ([_truncatedIndexPaths containsObject:indexPath]) {
      cell.accessoryType = UITableViewCellAccessoryDetailButton;
    } else {
      CGSize textSize = [cell.textLabel.text
          sizeWithAttributes:@{NSFontAttributeName : cell.textLabel.font}];
      // if width larger, height larger, or contains new line
      BOOL isTruncated =
          textSize.width > cell.contentView.bounds.size.width ||
          textSize.height > cell.contentView.bounds.size.height ||
          [cell.textLabel.text containsString:@"\n"];
      if (isTruncated) {
        [_truncatedIndexPaths addObject:indexPath];
        if (!expanded) {
          cell.accessoryType = UITableViewCellAccessoryDetailButton;
        }
      }
    }
  }

  if (indexPath.section == 0 && indexPath.row == _clearLogRow) {
    cell.textLabel.textColor = NSPusherManager.sharedController.activeTintColor;
  }

  if (indexPath.section == 0 && indexPath.row == _logEnabledSwitchRow) {
    UISwitch* logEnabledSwitch = [UISwitch new];
    logEnabledSwitch.on = _logEnabled;
    [logEnabledSwitch addTarget:self
                         action:@selector(updateLogEnabled:)
               forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = logEnabledSwitch;
  }

  return cell;
}

- (void)tableView:(UITableView*)tableView
    accessoryButtonTappedForRowWithIndexPath:(NSIndexPath*)indexPath {
  if (indexPath.section < _firstLogSection) {
    return;
  }
  BOOL expanded = [_expandedIndexPaths containsObject:indexPath];
  // only add expand / collapse option if currently expanded or if it is being
  // truncated
  if (expanded || [_truncatedIndexPaths containsObject:indexPath]) {
    if (expanded) {
      [_expandedIndexPaths removeObject:indexPath];
    } else {
      [_expandedIndexPaths addObject:indexPath];
    }
    [tableView reloadRowsAtIndexPaths:@[ indexPath ]
                     withRowAnimation:UITableViewRowAnimationAutomatic];
  }
}

- (void)networkResponseFilterUpdated:(UISegmentedControl*)segmentedControl {
  int idx = segmentedControl.selectedSegmentIndex;
  if (idx == 0) { // any
    _filteredNetworkResponse = nil;
  } else {
    _filteredNetworkResponse = NETWORK_RESPONSE_ITEMS[idx];
  }
  [self updateLogAndReload];
}

- (void)endResultFilterUpdated:(UISegmentedControl*)segmentedControl {
  int idx = segmentedControl.selectedSegmentIndex;
  if (idx == 0) { // any
    _filteredEndResult = nil;
  } else {
    _filteredEndResult = END_RESULT_ITEMS[idx];
  }
  [self updateLogAndReload];
}

@end
