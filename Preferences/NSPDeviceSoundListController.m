#import "NSPDeviceSoundListController.h"
#import "NSPLocalization.h"

#import "../Generated/BuiltinServices.generated.h"
#import "../Shared/NSPushPrefsStore.h"
#import "../global.h"
#import "../helpers.h"
#import "NSPSharedSpecifiers.h"
#import <notify.h>

@implementation NSPDeviceSoundListController

- (void)viewDidLoad {
  [super viewDidLoad];

  // Create buttons
  _updateBn = [[UIBarButtonItem alloc] initWithTitle:NSPLocalizedString(@"Update", nil)
                                               style:UIBarButtonItemStylePlain
                                              target:self
                                              action:@selector(updateItems)];
  _activityIndicator = [[UIActivityIndicatorView alloc]
      initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  _activityIndicatorBn =
      [[UIBarButtonItem alloc] initWithCustomView:_activityIndicator];

  _prefsKey = [self.specifier propertyForKey:@"prefsKey"];
  _service = [self.specifier propertyForKey:@"service"];
  _isSound = [self isSoundMode];
  _isCustomApp = NSPushBoolResolved(
      [self.specifier propertyForKey:@"isCustomApp"], NO);
  if (_isCustomApp) {
    _customAppIDKey = [self.specifier propertyForKey:@"customAppIDKey"];
  }

  _onlyAllowOne = [self onlyAllowOne];
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

  NSDictionary* builtInServices =
      NSPushDictionaryValue(_prefs[NSPPreferenceBuiltInServicesKey]) ?: @{};
  NSDictionary* serviceObj =
      NSPushDictionaryValue(builtInServices[_service]) ?: @{};
  NSString* subkey = [self storageKey];
  NSArray* val = nil;
  if (_isCustomApp) {
    NSDictionary* customApps =
        NSPushDictionaryValue(serviceObj[NSPPreferenceServiceCustomAppsKey])
        ?: @{};
    NSDictionary* customApp =
        NSPushDictionaryValue(customApps[_customAppIDKey]) ?: @{};
    val = NSPushArrayValue(customApp[subkey]) ?: @[];
  } else {
    val = NSPushArrayValue(serviceObj[subkey]) ?: @[];
  }
  _serviceItems = [NSMutableArray new];
  for (id rawItem in val) {
    if (![rawItem isKindOfClass:NSDictionary.class]) {
      continue;
    }
    NSDictionary* item = (NSDictionary*)rawItem;
    // Reject malformed entries up front so later code can safely treat every
    // service item as a mutable dictionary with string name/id values.
    if (![item[@"name"] isKindOfClass:NSString.class] ||
        ![item[@"id"] isKindOfClass:NSString.class]) {
      continue;
    }
    [_serviceItems addObject:[item mutableCopy]];
  }

  [self reloadSpecifiers];

  // Update in background
  [self updateItems];
}

- (void)showActivityIndicator {
  self.navigationItem.rightBarButtonItem = _activityIndicatorBn;
  [_activityIndicator startAnimating];
}

- (void)hideActivityIndicator {
  dispatch_async(dispatch_get_main_queue(), ^{
    [_activityIndicator stopAnimating];
    self.navigationItem.rightBarButtonItem = _updateBn;
  });
}

- (void)saveServiceItems {
  NSString* subkey = [self storageKey];
  if (_isCustomApp) {
    NSMutableDictionary* customApp = [[NSPushPrefsStore
        customAppPrefsForService:_service
                    customAppID:_customAppIDKey
                isCustomService:NO] mutableCopy];
    customApp[subkey] = _serviceItems;
    [NSPushPrefsStore setCustomAppPrefs:customApp
                             forService:_service
                           customAppID:_customAppIDKey
                       isCustomService:NO
                          shouldNotify:YES];
  } else {
    NSMutableDictionary* serviceObj = [[NSPushPrefsStore
        serviceForName:_service isCustomService:NO] mutableCopy];
    serviceObj[subkey] = _serviceItems;
    [NSPushPrefsStore setService:serviceObj
                         forName:_service
                 isCustomService:NO
                    shouldNotify:YES];
  }
}

- (void)updateItems {
  [self showActivityIndicator];

  if (XEq(_service, PUSHER_SERVICE_PUSHOVER)) {
    [self updatePushoverItems];
  } else if (XEq(_service, PUSHER_SERVICE_PUSHBULLET)) {
    [self updatePushbulletItems];
  }
}

- (NSArray*)specifiers {
  if (!_specifiers) {
    NSMutableArray* allSpecifiers = [NSMutableArray new];

    if (_serviceItems.count) {
      PSSpecifier* groupSpecifier = [PSSpecifier emptyGroupSpecifier];
      NSString* footer = [self footerText];
      if (footer) {
        [groupSpecifier setProperty:footer forKey:@"footerText"];
      }
      [allSpecifiers addObject:groupSpecifier];
    }

    for (NSDictionary* item in [self sortedItemList:_serviceItems]) {
      if (![item isKindOfClass:NSDictionary.class] ||
          ![item[@"name"] isKindOfClass:NSString.class] ||
          ![item[@"id"] isKindOfClass:NSString.class]) {
        continue;
      }
      PSSpecifier* switchSpecifier = [PSSpecifier
          preferenceSpecifierNamed:item[@"name"]
                            target:self
                               set:@selector(
                                       setPreferenceValue:forItemSpecifier:)
                               get:@selector(readItemPreferenceValue:)
                            detail:nil
                              cell:PSSwitchCell
                              edit:nil];
      switchSpecifier.identifier = item[@"id"];
      [switchSpecifier setProperty:@PUSHER_PREFS_NOTIFICATION
                            forKey:@"PostNotification"];
      [switchSpecifier setProperty:@YES forKey:@"enabled"];
      [switchSpecifier setProperty:@"com.noahsaso.pusher" forKey:@"defaults"];
      [switchSpecifier setProperty:@NO forKey:@"default"];
      [allSpecifiers addObject:switchSpecifier];
    }

    _specifiers = [allSpecifiers copy];
  }

  return _specifiers;
}

- (NSArray*)sortedItemList:(NSArray*)items {
  return [items sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
    if (![obj1 isKindOfClass:NSDictionary.class] ||
        ![obj2 isKindOfClass:NSDictionary.class]) {
      return NSOrderedSame;
    }
    NSDictionary* item1 = (NSDictionary*)obj1;
    NSDictionary* item2 = (NSDictionary*)obj2;
    NSString* name1 = [item1[@"name"] isKindOfClass:NSString.class]
                          ? (NSString*)item1[@"name"]
                          : @"";
    NSString* name2 = [item2[@"name"] isKindOfClass:NSString.class]
                          ? (NSString*)item2[@"name"]
                          : @"";
    return [name1 localizedCaseInsensitiveCompare:name2];
  }];
}

- (void)setPreferenceValue:(id)value forItemSpecifier:(PSSpecifier*)specifier {
  for (id rawItem in _serviceItems) {
    if (![rawItem isKindOfClass:NSMutableDictionary.class]) {
      continue;
    }
    NSMutableDictionary* item = (NSMutableDictionary*)rawItem;
    id itemID = item[@"id"];
    if ([itemID isKindOfClass:NSString.class] &&
        XEq(itemID, specifier.identifier)) {
      item[@"enabled"] = value;
    } else if (_onlyAllowOne) {
      // all others must be off
      item[@"enabled"] = @NO;
    }
  }
  // reload specifiers because likely turned other switch off
  if (_onlyAllowOne) {
    [self reloadSpecifiers];
  }
  [self saveServiceItems];
}

- (id)readItemPreferenceValue:(PSSpecifier*)specifier {
  for (id rawItem in _serviceItems) {
    if (![rawItem isKindOfClass:NSDictionary.class]) {
      continue;
    }
    NSDictionary* item = (NSDictionary*)rawItem;
    id itemID = item[@"id"];
    if ([itemID isKindOfClass:NSString.class] &&
        XEq(itemID, specifier.identifier)) {
      return item[@"enabled"];
    }
  }
  return @NO;
}


#pragma mark - Subclass hooks

- (BOOL)isSoundMode {
  return NSPushBoolResolved([self.specifier propertyForKey:@"isSound"], NO);
}

- (NSString*)storageKey {
  return [self isSoundMode] ? @"sounds" : @"devices";
}

- (BOOL)onlyAllowOne {
  return [self isSoundMode] || XEq(_service, PUSHER_SERVICE_PUSHBULLET);
}

- (NSString*)footerText {
  return nil;
}

- (void)updatePushoverItems {
  [self doesNotRecognizeSelector:_cmd];
}

- (void)updatePushbulletItems {
  [self doesNotRecognizeSelector:_cmd];
}

@end
