#import <MobileCoreServices/LSApplicationProxy.h>

#import "NSPAppMultiSelectionController.h"
#import "NSPCustomAppController.h"
#import "NSPCustomizeAppsController.h"
#import "NSPSharedSpecifiers.h"
#import "UIImageIcon.h"
#import "NSPusherManager.h"

#import "../Generated/BuiltinServices.generated.h"
#import "../global.h"
#import "../helpers.h"
#import <notify.h>

@implementation NSPCustomizeAppsController

- (void)setAppDefaults:(NSString*)appID {
  if ([_customApps.allKeys containsObject:appID]) {
    NSMutableDictionary* appDict =
        [(NSDictionary*)_customApps[appID] mutableCopy];
    appDict[@"enabled"] = @YES;
    _customApps[appID] = appDict;
  } else {
    NSMutableDictionary* defaultDict = [@{@"enabled" : @YES} mutableCopy];
    if (XEq(_service, PUSHER_SERVICE_PUSHOVER) ||
        XEq(_service, PUSHER_SERVICE_PUSHBULLET)) {
      defaultDict[@"devices"] = _defaultDevices;
    }
    if (XEq(_service, PUSHER_SERVICE_PUSHOVER)) {
      defaultDict[@"sounds"] = _defaultSounds;
    }
    if (XEq(_service, PUSHER_SERVICE_IFTTT)) {
      defaultDict[@"eventName"] = _defaultEventName;
    }
    if (_isCustomService || XEq(_service, PUSHER_SERVICE_IFTTT) ||
        XEq(_service, PUSHER_SERVICE_PUSHER_RECEIVER)) {
      defaultDict[@"includeIcon"] = _defaultIncludeIcon;
    }
    if (_isCustomService || XEq(_service, PUSHER_SERVICE_PUSHER_RECEIVER)) {
      defaultDict[@"includeImage"] = _defaultIncludeImage;
      defaultDict[@"imageMaxWidth"] = _defaultImageMaxWidth;
      defaultDict[@"imageMaxHeight"] = _defaultImageMaxHeight;
      defaultDict[@"imageShrinkFactor"] = _defaultImageShrinkFactor;
    }
    if (_isCustomService || XEq(_service, PUSHER_SERVICE_IFTTT)) {
      defaultDict[@"curateData"] = _defaultCurateData;
    }
    _customApps[appID] = defaultDict;
  }
}

- (void)saveAppState {
  NSArray* appIDs = _data[@"Apps"];
  for (NSString* appID in appIDs) {
    [self setAppDefaults:appID];
  }
  for (NSString* appID in _customApps.allKeys) {
    if (![appIDs containsObject:appID]) {
      [_customApps removeObjectForKey:appID];
    }
  }
  [self updateTitle];
  if (_isCustomService) {
    NSMutableDictionary* customServices = [(
        [NSPSharedSpecifiers
            getPreference:(__bridge CFStringRef)NSPPreferenceCustomServicesKey]
            ?: @{}) mutableCopy];
    NSMutableDictionary* serviceObj =
        [(customServices[_service] ?: @{}) mutableCopy];
    serviceObj[NSPPreferenceServiceCustomAppsKey] = _customApps;
    customServices[_service] = serviceObj;
    [NSPSharedSpecifiers
        setPreference:(__bridge CFStringRef)NSPPreferenceCustomServicesKey
                value:(__bridge CFPropertyListRef)customServices
         shouldNotify:YES];
  } else {
    NSMutableDictionary* builtInServices = [(
        [NSPSharedSpecifiers
            getPreference:(__bridge CFStringRef)NSPPreferenceBuiltInServicesKey]
            ?: @{}) mutableCopy];
    NSMutableDictionary* serviceObj =
        [(builtInServices[_service] ?: @{}) mutableCopy];
    serviceObj[NSPPreferenceServiceCustomAppsKey] = _customApps;
    builtInServices[_service] = serviceObj;
    [NSPSharedSpecifiers
        setPreference:(__bridge CFStringRef)NSPPreferenceBuiltInServicesKey
                value:(__bridge CFPropertyListRef)builtInServices
         shouldNotify:YES];
  }
}

- (void)viewDidLoad {
  [super viewDidLoad];

  // _appList = [ALApplicationList sharedApplicationList];

  _service = [self.specifier propertyForKey:@"service"];
  _isCustomService =
      [self.specifier propertyForKey:@"isCustomService"] &&
      ((NSNumber*)[self.specifier propertyForKey:@"isCustomService"]).boolValue;

  _lastTargetAppID = nil;
  _lastTargetIndexPath = nil;

  _loadedAppControllers = [NSMutableDictionary new];

  CGRect tableFrame = self.view.bounds;
  if ([[UIDevice currentDevice] userInterfaceIdiom] ==
      UIUserInterfaceIdiomPad) {
    tableFrame = self.rootController.view.bounds;
  }
  _table = [[UITableView alloc] initWithFrame:tableFrame
                                        style:UITableViewStyleGrouped];
  [_table registerClass:UITableViewCell.class
      forCellReuseIdentifier:@"CustomAppCell"];
  _table.dataSource = self;
  _table.delegate = self;
  [self.view addSubview:_table];

  self.navigationItem.title = @"App Customization";
  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:@"Edit"
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(toggleEditing:)];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  // End editing of previous view controller so updates prefs if editing text
  // field
  if (self.navigationController.viewControllers &&
      self.navigationController.viewControllers.count > 1) {
    UIViewController* viewController =
        self.navigationController
            .viewControllers[self.navigationController.viewControllers.count -
                             2];
    if (viewController) {
      [viewController.view endEditing:YES];
    }
  }

  // Get preferences
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

  NSDictionary* serviceDefaults = nil;
  if (_isCustomService) {
    serviceDefaults =
        (prefs[NSPPreferenceCustomServicesKey] ?: @{})[_service] ?: @{};
    _customApps = [(serviceDefaults[NSPPreferenceServiceCustomAppsKey]
                        ?: @{}) mutableCopy];
  } else {
    NSDictionary* builtInServices =
        (NSDictionary*)prefs[NSPPreferenceBuiltInServicesKey] ?: @{};
    serviceDefaults = builtInServices[_service] ?: @{};
    _customApps = [(serviceDefaults[NSPPreferenceServiceCustomAppsKey]
                        ?: @{}) mutableCopy];
  }

  _label = [self.specifier.name componentsSeparatedByString:@" ("][0];
  [self updateTitle];

  if (XEq(_service, PUSHER_SERVICE_PUSHOVER) ||
      XEq(_service, PUSHER_SERVICE_PUSHBULLET)) {
    _defaultDevices =
        [(serviceDefaults[[self.specifier propertyForKey:@"defaultDevicesKey"]]
              ?: @[]) copy];
  }
  if (XEq(_service, PUSHER_SERVICE_PUSHOVER)) {
    _defaultSounds =
        [(serviceDefaults[[self.specifier propertyForKey:@"defaultSoundsKey"]]
              ?: @[]) copy];
  }
  if (XEq(_service, PUSHER_SERVICE_IFTTT)) {
    _defaultEventName = [(
        serviceDefaults[[self.specifier propertyForKey:@"defaultEventNameKey"]]
            ?: @"") copy];
    _defaultIncludeIcon = [(serviceDefaults[[self.specifier
                                propertyForKey:@"defaultIncludeIconKey"]]
                                ?: @NO) copy];
    _defaultCurateData = [(
        serviceDefaults[[self.specifier propertyForKey:@"defaultCurateDataKey"]]
            ?: @YES) copy];
  }
  if (XEq(_service, PUSHER_SERVICE_PUSHER_RECEIVER)) {
    _defaultIncludeIcon = [(serviceDefaults[[self.specifier
                                propertyForKey:@"defaultIncludeIconKey"]]
                                ?: @YES) copy];
    _defaultIncludeImage = [(serviceDefaults[[self.specifier
                                 propertyForKey:@"defaultIncludeImageKey"]]
                                 ?: @YES) copy];
    _defaultImageMaxWidth = [(serviceDefaults[[self.specifier
                                  propertyForKey:@"defaultImageMaxWidthKey"]]
                                  ?: @(PUSHER_DEFAULT_MAX_WIDTH)) copy];
    _defaultImageMaxHeight = [(serviceDefaults[[self.specifier
                                   propertyForKey:@"defaultImageMaxHeightKey"]]
                                   ?: @(PUSHER_DEFAULT_MAX_HEIGHT)) copy];
    _defaultImageShrinkFactor =
        [(serviceDefaults[
              [self.specifier propertyForKey:@"defaultImageShrinkFactorKey"]]
              ?: @(PUSHER_DEFAULT_SHRINK_FACTOR)) copy];
  }
  if (_isCustomService) {
    _defaultIncludeIcon = [(serviceDefaults[[self.specifier
                                propertyForKey:@"defaultIncludeIconKey"]]
                                ?: @NO) copy];
    _defaultIncludeImage = [(serviceDefaults[[self.specifier
                                 propertyForKey:@"defaultIncludeImageKey"]]
                                 ?: @NO) copy];
    _defaultImageMaxWidth = [(serviceDefaults[[self.specifier
                                  propertyForKey:@"defaultImageMaxWidthKey"]]
                                  ?: @(PUSHER_DEFAULT_MAX_WIDTH)) copy];
    _defaultImageMaxHeight = [(serviceDefaults[[self.specifier
                                   propertyForKey:@"defaultImageMaxHeightKey"]]
                                   ?: @(PUSHER_DEFAULT_MAX_HEIGHT)) copy];
    _defaultImageShrinkFactor =
        [(serviceDefaults[
              [self.specifier propertyForKey:@"defaultImageShrinkFactorKey"]]
              ?: @(PUSHER_DEFAULT_SHRINK_FACTOR)) copy];
  }

  _sections = @[ @"", @"Apps" ];
  _data = [@{
    @"" : @[ @"Add Apps" ],
    @"Apps" : [NSMutableArray new],
  } mutableCopy];

  [_data[@"Apps"] addObjectsFromArray:_customApps.allKeys];

  [self sortAppIDArray:_data[@"Apps"]];

  [_table reloadData];
}

- (void)updateTitle {
  self.specifier.name = XStr(@"%@ (%d total)", _label, (int)_customApps.count);
  // psListRef is stored as a non-retaining NSValue to avoid a retain cycle
  // (controller -> specifiers -> psListRef -> controller); unwrap it here.
  NSValue* psListRefValue =
      (NSValue*)[self.specifier propertyForKey:@"psListRef"];
  PSListController* listController =
      (PSListController*)psListRefValue.nonretainedObjectValue;
  if (listController) {
    [listController reloadSpecifier:self.specifier];
  }
}

- (void)sortAppIDArray:(NSMutableArray*)array {
  [array sortUsingComparator:^NSComparisonResult(NSString* appID1,
                                                 NSString* appID2) {
    LSApplicationProxy* firstProxy =
        [LSApplicationProxy applicationProxyForIdentifier:appID1];
    LSApplicationProxy* secondProxy =
        [LSApplicationProxy applicationProxyForIdentifier:appID2];
    NSString* first = [firstProxy localizedName];
    NSString* second = [secondProxy localizedName];
    return [first localizedCaseInsensitiveCompare:second];
  }];
}

- (void)toggleEditing:(UIBarButtonItem*)barButtonItem {
  [_table setEditing:![_table isEditing] animated:YES];
  barButtonItem.title = [_table isEditing] ? @"Done" : @"Edit";
}

- (void)addAppIDs:(NSArray*)appIDs {
  NSMutableArray* nonOverlappingAppIDs = [NSMutableArray new];
  for (NSString* appID in appIDs) {
    if (![_data[@"Apps"] containsObject:appID]) {
      [nonOverlappingAppIDs addObject:appID];
    }
  }
  [_data[@"Apps"] addObjectsFromArray:nonOverlappingAppIDs];
  [self sortAppIDArray:_data[@"Apps"]];
  [self saveAppState];
  [_table reloadData];
}

- (void)tableView:(UITableView*)table
    didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [table deselectRowAtIndexPath:indexPath animated:YES];
  // Non-App
  if (indexPath.section == 0) {
    NSPAppMultiSelectionController* appSelectionController =
        [NSPAppMultiSelectionController new];
    [appSelectionController setCallback:^(id appIDs) {
      [self addAppIDs:(NSArray*)appIDs];
    }];
    // appSelectionController.navItemTitle = @"Add Apps";
    // appSelectionController.rightButtonTitle = @"Add";
    // appSelectionController.selectingMultiple = YES;
    appSelectionController.useSearchBar = YES;
    UINavigationController* navController = [[UINavigationController alloc]
        initWithRootViewController:appSelectionController];
    navController.navigationBar.tintColor =
        NSPusherManager.sharedController.activeTintColor;
    [self presentViewController:navController animated:YES completion:nil];
    return;
  }
  NSString* appID = _data[_sections[indexPath.section]][indexPath.row];
  NSPCustomAppController* controller;
  if ([_loadedAppControllers.allKeys containsObject:appID]) {
    controller = _loadedAppControllers[appID];
  } else {
    LSApplicationProxy* appProxy =
        [LSApplicationProxy applicationProxyForIdentifier:appID];
    NSString* appTitle;
    if (appProxy == nil) {
      appTitle = @"UNKNOWN APP";
    } else {
      appTitle = [appProxy localizedName];
    }
    // NSString *appTitle = _appList.applications[appID] ?: @"UNKNOWN APP";
    controller =
        [[NSPCustomAppController alloc] initWithService:_service
                                                  appID:appID
                                               appTitle:appTitle
                                        isCustomService:_isCustomService];
    _loadedAppControllers[appID] = controller;
  }
  [self pushController:controller];
}

- (NSInteger)tableView:(UITableView*)table
    numberOfRowsInSection:(NSInteger)section {
  return ((NSArray*)_data[_sections[section]]).count;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)table {
  return _sections.count;
}

- (NSString*)tableView:(UITableView*)table
    titleForHeaderInSection:(NSInteger)section {
  NSString* title = _sections[section];
  if (XEq(title, @"Apps") && [self tableView:table
                                 numberOfRowsInSection:section] == 0) {
    title = @"No Apps";
  }
  return title;
}

- (UITableViewCell*)tableView:(UITableView*)table
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell =
      [table dequeueReusableCellWithIdentifier:@"CustomAppCell"
                                  forIndexPath:indexPath];
  NSString* appID = _data[_sections[indexPath.section]][indexPath.row];
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  cell.imageView.image = nil;
  // Non-App
  if (indexPath.section == 0) {
    cell.textLabel.text = appID;
    return cell;
  }
  LSApplicationProxy* firstProxy =
      [LSApplicationProxy applicationProxyForIdentifier:appID];
  cell.textLabel.text = [firstProxy localizedName];
  // cell.textLabel.text = _appList.applications[appID];
  cell.imageView.image = [UIImage
      _applicationIconImageForBundleIdentifier:appID
                                        format:0
                                         scale:[UIScreen mainScreen].scale];
  // cell.imageView.image = [_appList iconOfSize:ALApplicationIconSizeSmall
  //                        forDisplayIdentifier:appID];
  return cell;
}

- (UITableViewCellEditingStyle)tableView:(UITableView*)table
           editingStyleForRowAtIndexPath:(NSIndexPath*)indexPath {
  if (indexPath.section > 0) {
    return UITableViewCellEditingStyleDelete;
  }
  return UITableViewCellEditingStyleNone;
}

// Shared by the swipe action and commitEditingStyle (Edit mode), so the delete
// behavior stays in one place.
- (void)deleteAppAtRowAtIndexPath:(NSIndexPath*)indexPath
                          tableView:(UITableView*)tableView {
  [_data[_sections[indexPath.section]] removeObjectAtIndex:indexPath.row];
  [self saveAppState];

  [CATransaction begin];
  [tableView beginUpdates];
  if (((NSArray*)_data[_sections[indexPath.section]]).count == 0) {
    [CATransaction setCompletionBlock:^{
      [tableView reloadData];
    }];
  }
  [tableView deleteRowsAtIndexPaths:@[ indexPath ]
                   withRowAnimation:UITableViewRowAnimationAutomatic];
  [tableView endUpdates];
  [CATransaction commit];
}

// Implemented so the red minus buttons in Edit mode actually delete rows; the
// data source previously advertised Delete editing style but had no
// commitEditingStyle:, making Edit-mode deletion a no-op.
- (void)tableView:(UITableView*)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath*)indexPath {
  if (editingStyle == UITableViewCellEditingStyleDelete) {
    [self deleteAppAtRowAtIndexPath:indexPath tableView:tableView];
  }
}

- (UISwipeActionsConfiguration*)tableView:(UITableView*)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath {
  if (indexPath.section == 0) {
    return [UISwipeActionsConfiguration configurationWithActions:@[]];
  }

  UIContextualAction* deleteAction = [UIContextualAction
      contextualActionWithStyle:UIContextualActionStyleDestructive
                          title:@"Delete"
                        handler:^(UIContextualAction* action,
                                  UIView* sourceView,
                                  void (^completionHandler)(BOOL)) {
                          [self deleteAppAtRowAtIndexPath:indexPath
                                                 tableView:tableView];
                          completionHandler(YES);
                        }];

  UISwipeActionsConfiguration* actions =
      [UISwipeActionsConfiguration configurationWithActions:@[ deleteAction ]];
  actions.performsFirstActionWithFullSwipe =
      NO; // Set to NO if you don't want full swipe to perform the first action
          // automatically
  return actions;
}

// - (NSArray *)tableView:(UITableView *)table
//     editActionsForRowAtIndexPath:(NSIndexPath *)indexPath {
//   if (indexPath.section == 0) {
//     return @[];
//   }
//   UITableViewRowAction *deleteAction = [UITableViewRowAction
//       rowActionWithStyle:UITableViewRowActionStyleDestructive
//                    title:@"Delete"
//                  handler:^(UITableViewRowAction *action,
//                            NSIndexPath *indexPath) {
//                    [_data[_sections[indexPath.section]]
//                        removeObjectAtIndex:indexPath.row];
//                    [self saveAppState];

//                    // do all this fancy transition stuff to animate header to
//                    // 'No Apps' if last one deleted (unnecessary but user
//                    // experience is TOP priority!11!!!1)
//                    [CATransaction begin];
//                    [table beginUpdates];
//                    if (((NSArray *)_data[_sections[indexPath.section]]).count
//                    ==
//                        0) {
//                      [CATransaction setCompletionBlock:^{
//                        [table reloadData];
//                      }];
//                    }
//                    [table
//                        deleteRowsAtIndexPaths:@[ indexPath ]
//                              withRowAnimation:UITableViewRowAnimationAutomatic];
//                    [table endUpdates];
//                    [CATransaction commit];
//                  }];
//   return @[ deleteAction ];
// }

- (BOOL)tableView:(UITableView*)tableView
    shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath*)indexPath {
  return indexPath.section > 0;
}

@end
