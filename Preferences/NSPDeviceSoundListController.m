#import "NSPDeviceSoundListController.h"

#import "../Generated/BuiltinServices.generated.h"
#import "../global.h"
#import "../helpers.h"
#import "NSPSharedSpecifiers.h"
#import <notify.h>

static NSDictionary* NSPJSONDictionary(id object) {
  return [object isKindOfClass:NSDictionary.class] ? (NSDictionary*)object : @{};
}

@implementation NSPDeviceSoundListController

- (void)viewDidLoad {
  [super viewDidLoad];

  // Create buttons
  _updateBn = [[UIBarButtonItem alloc] initWithTitle:@"Update"
                                               style:UIBarButtonItemStylePlain
                                              target:self
                                              action:@selector(updateItems)];
  _activityIndicator = [[UIActivityIndicatorView alloc]
      initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  _activityIndicatorBn =
      [[UIBarButtonItem alloc] initWithCustomView:_activityIndicator];

  _prefsKey = [self.specifier propertyForKey:@"prefsKey"];
  _service = [self.specifier propertyForKey:@"service"];
  _isSound = NSPushBoolResolved([self.specifier propertyForKey:@"isSound"], NO);
  _isCustomApp = NSPushBoolResolved(
      [self.specifier propertyForKey:@"isCustomApp"], NO);
  if (_isCustomApp) {
    _customAppIDKey = [self.specifier propertyForKey:@"customAppIDKey"];
  }

  _onlyAllowOne = _isSound || XEq(_service, PUSHER_SERVICE_PUSHBULLET);
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
  NSString* subkey = _isSound ? @"sounds" : @"devices";
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
  NSMutableDictionary* builtInServices =
      [(NSPushDictionaryValue([NSPSharedSpecifiers
            getPreference:(__bridge CFStringRef)NSPPreferenceBuiltInServicesKey]) ?: @{}) mutableCopy];
  NSMutableDictionary* serviceObj =
      [(NSPushDictionaryValue(builtInServices[_service]) ?: @{}) mutableCopy];
  NSString* subkey = _isSound ? @"sounds" : @"devices";
  if (_isCustomApp) {
    NSMutableDictionary* customApps =
        [(NSPushDictionaryValue(serviceObj[NSPPreferenceServiceCustomAppsKey]) ?: @{}) mutableCopy];
    NSMutableDictionary* customApp =
        [(NSPushDictionaryValue(customApps[_customAppIDKey]) ?: @{}) mutableCopy];
    customApp[subkey] = _serviceItems;
    customApps[_customAppIDKey] = customApp;
    serviceObj[NSPPreferenceServiceCustomAppsKey] = customApps;
  } else {
    serviceObj[subkey] = _serviceItems;
  }
  builtInServices[_service] = serviceObj;
  [NSPSharedSpecifiers
      setPreference:(__bridge CFStringRef)NSPPreferenceBuiltInServicesKey
              value:(__bridge CFPropertyListRef)builtInServices
       shouldNotify:YES];
}

- (void)updateItems {
  [self showActivityIndicator];

  if (XEq(_service, PUSHER_SERVICE_PUSHOVER)) {
    if (_isSound) {
      [self updatePushoverSounds];
    } else {
      [self updatePushoverDevices];
    }
  } else if (XEq(_service, PUSHER_SERVICE_PUSHBULLET)) {
    if (_isSound) {
      [self updatePushbulletSounds];
    } else {
      [self updatePushbulletDevices];
    }
  }
}

- (NSArray*)specifiers {
  if (!_specifiers) {
    NSMutableArray* allSpecifiers = [NSMutableArray new];

    if (_serviceItems.count) {
      PSSpecifier* groupSpecifier = [PSSpecifier emptyGroupSpecifier];
      if (!_isSound) {
        if (XEq(_service, PUSHER_SERVICE_PUSHOVER)) {
          [groupSpecifier setProperty:@"Selecting none will forward push "
                                      @"notifications to all devices."
                               forKey:@"footerText"];
        } else if (XEq(_service, PUSHER_SERVICE_PUSHBULLET)) {
          [groupSpecifier
              setProperty:@"Pushbullet only allows one receiving device. "
                          @"Selecting none "
                          @"will forward push notifications to all devices."
                   forKey:@"footerText"];
        }
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

- (void)updatePushoverDevices {
  NSDictionary* builtInServices =
      NSPushDictionaryValue(_prefs[NSPPreferenceBuiltInServicesKey]) ?: @{};
  NSDictionary* serviceObj =
      NSPushDictionaryValue(builtInServices[_service]) ?: @{};
  NSString* pushoverToken =
      XStrDefault(serviceObj[NSPPreferenceServiceTokenKey], @"");
  NSString* pushoverUser =
      XStrDefault(serviceObj[NSPPreferenceServiceUserKey], @"");
  NSDictionary* userDictionary =
      @{@"token" : pushoverToken, @"user" : pushoverUser};
  NSData* jsonData =
      [NSJSONSerialization dataWithJSONObject:userDictionary
                                      options:NSJSONWritingPrettyPrinted
                                        error:nil];
  NSMutableURLRequest* request = [NSMutableURLRequest
       requestWithURL:
           [NSURL
               URLWithString:@"https://api.pushover.net/1/users/validate.json"]
          cachePolicy:NSURLRequestUseProtocolCachePolicy
      timeoutInterval:10];
  [request setHTTPMethod:@"POST"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [request setValue:XStr(@"%d", (int)jsonData.length)
      forHTTPHeaderField:@"Content-length"];
  [request setHTTPBody:jsonData];

  // use async way to connect network
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response,
                            NSError* error) {
          // Run the whole response handling on the main thread: _serviceItems
          // is mutated here and read by the table view, so touching it from
          // NSURLSession's background queue races with cell rendering.
          dispatch_async(dispatch_get_main_queue(), ^{
          if (data.length && error == nil) {
            XLog(@"Success");
            NSError* jsonError = nil;
            NSDictionary* json = NSPJSONDictionary(
                [NSJSONSerialization JSONObjectWithData:data
                                               options:kNilOptions
                                                 error:&jsonError]);
            if (jsonError) {
              XLog(@"JSON Error: %@", jsonError);
            }
            // 0 error, 1 success
            int status = (int)NSPushIntegerValue(json[@"status"], 0);
            if (status == 0) {
              XLog(@"Something went wrong");
              NSArray* errors =
                  [json[@"errors"] isKindOfClass:NSArray.class]
                      ? (NSArray*)json[@"errors"]
                      : nil;
              NSString* title;
              NSString* msg = @"";
              if (errors == nil || errors.count == 0) {
                title = @"Unknown Error";
                msg = XStr(@"Server response: %@", json);
              } else {
                title = @"Server Error";
                msg = XStr(@"%@", [errors componentsJoinedByString:@"\n"]);
              }
              UIAlertController* alert = XAlertTitle(title, msg);
              id handler = ^(UIAlertAction* action) {
                [self.navigationController popViewControllerAnimated:YES];
              };
              [alert addAction:XAlertBtnHandler(@"Ok", handler)];
              dispatch_async(dispatch_get_main_queue(), ^{
                [self presentViewController:alert animated:YES completion:nil];
              });
              [self hideActivityIndicator];
              return;
            }

            id rawDevices = json[@"devices"];
            NSMutableArray* serviceDevices =
                [rawDevices isKindOfClass:NSArray.class]
                    ? [(NSArray*)rawDevices mutableCopy]
                    : [NSMutableArray new];
            NSMutableArray* serviceDevicesToRemove = [NSMutableArray new];
            for (NSDictionary* device in _serviceItems) {
              if (![serviceDevices containsObject:device[@"id"]]) {
                [serviceDevicesToRemove addObject:device];
              } else {
                [serviceDevices removeObject:device[@"id"]];
              }
            }
            for (id rawDevice in serviceDevices) {
              if (![rawDevice isKindOfClass:NSString.class] ||
                  [(NSString*)rawDevice length] == 0) {
                continue;
              }
              NSString* device = (NSString*)rawDevice;
              [_serviceItems addObject:[@{
                               @"name" : device,
                               @"id" : device,
                               @"enabled" : @NO
                             } mutableCopy]];
            }
            for (NSDictionary* device in serviceDevicesToRemove) {
              [_serviceItems removeObject:device];
            }

            [self saveServiceItems];

            XLog(@"Saved devices");

            // Reload specifiers on current screen
            dispatch_async(dispatch_get_main_queue(), ^{
              [self reloadSpecifiers];
            });

          } else {
            id handler = ^(UIAlertAction* action) {
              [self.navigationController popViewControllerAnimated:YES];
            };
            NSString* msg;
            if (data.length == 0 && error == nil) {
              msg = @"Server did not respond. Please check your internet "
                    @"connection or try again later.";
            } else if (error) {
              msg = error.localizedDescription;
            } else {
              msg = @"Unknown Error. Contact Developer.";
            }
            UIAlertController* alert = XAlertTitle(@"Network Error", msg);
            [alert addAction:XAlertBtnHandler(@"Ok", handler)];
            dispatch_async(dispatch_get_main_queue(), ^{
              [self presentViewController:alert animated:YES completion:nil];
            });
          }

          [self hideActivityIndicator];
          });
        }] resume];
}

- (void)updatePushoverSounds {
  NSDictionary* builtInServices =
      NSPushDictionaryValue(_prefs[NSPPreferenceBuiltInServicesKey]) ?: @{};
  NSDictionary* serviceObj =
      NSPushDictionaryValue(builtInServices[_service]) ?: @{};
  NSString* pushoverToken =
      XStrDefault(serviceObj[NSPPreferenceServiceTokenKey], @"");
  NSMutableURLRequest* request = [NSMutableURLRequest
       requestWithURL:[NSURL URLWithString:XStr(@"https://api.pushover.net/1/"
                                                @"sounds.json?token=%@",
                                                pushoverToken)]
          cachePolicy:NSURLRequestUseProtocolCachePolicy
      timeoutInterval:10];
  [request setHTTPMethod:@"GET"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

  // use async way to connect network
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response,
                            NSError* error) {
          // Run the whole response handling on the main thread: _serviceItems
          // is mutated here and read by the table view, so touching it from
          // NSURLSession's background queue races with cell rendering.
          dispatch_async(dispatch_get_main_queue(), ^{
          if (data.length && error == nil) {
            XLog(@"Success");
            NSError* jsonError = nil;
            NSDictionary* json = NSPJSONDictionary(
                [NSJSONSerialization JSONObjectWithData:data
                                               options:kNilOptions
                                                 error:&jsonError]);
            if (jsonError) {
              XLog(@"JSON Error: %@", jsonError);
            }
            // 0 error, 1 success
            int status = (int)NSPushIntegerValue(json[@"status"], 0);
            if (status == 0) {
              XLog(@"Something went wrong");
              NSArray* errors =
                  [json[@"errors"] isKindOfClass:NSArray.class]
                      ? (NSArray*)json[@"errors"]
                      : nil;
              NSString* title;
              NSString* msg = @"";
              if (errors == nil || errors.count == 0) {
                title = @"Unknown Error";
                msg = XStr(@"Server response: %@", json);
              } else {
                title = @"Server Error";
                msg = XStr(@"%@", [errors componentsJoinedByString:@"\n"]);
              }
              UIAlertController* alert = XAlertTitle(title, msg);
              id handler = ^(UIAlertAction* action) {
                [self.navigationController popViewControllerAnimated:YES];
              };
              [alert addAction:XAlertBtnHandler(@"Ok", handler)];
              dispatch_async(dispatch_get_main_queue(), ^{
                [self presentViewController:alert animated:YES completion:nil];
              });
              [self hideActivityIndicator];
              return;
            }

            id rawSounds = json[@"sounds"];
            NSMutableDictionary* serviceSounds =
                [rawSounds isKindOfClass:NSDictionary.class]
                    ? [(NSDictionary*)rawSounds mutableCopy]
                    : [NSMutableDictionary new];

            NSMutableArray* serviceSoundsToRemove = [NSMutableArray new];
            for (NSDictionary* sound in _serviceItems) {
              if (![serviceSounds.allKeys containsObject:sound[@"id"]]) {
                [serviceSoundsToRemove addObject:sound];
              } else {
                [serviceSounds removeObjectForKey:sound[@"id"]];
              }
            }
            for (NSString* soundID in serviceSounds.allKeys) {
              id rawName = serviceSounds[soundID];
              NSString* name = [rawName isKindOfClass:NSString.class]
                                   ? (NSString*)rawName
                                   : soundID;
              [_serviceItems addObject:[@{
                               @"name" : name,
                               @"id" : soundID,
                               @"enabled" : @NO
                             } mutableCopy]];
            }
            for (NSDictionary* sound in serviceSoundsToRemove) {
              [_serviceItems removeObject:sound];
            }

            [self saveServiceItems];

            XLog(@"Saved sounds");

            // Reload specifiers on current screen
            dispatch_async(dispatch_get_main_queue(), ^{
              [self reloadSpecifiers];
            });

          } else {
            id handler = ^(UIAlertAction* action) {
              [self.navigationController popViewControllerAnimated:YES];
            };
            NSString* msg;
            if (data.length == 0 && error == nil) {
              msg = @"Server did not respond. Please check your internet "
                    @"connection or try again later.";
            } else if (error) {
              msg = error.localizedDescription;
            } else {
              msg = @"Unknown Error. Contact Developer.";
            }
            UIAlertController* alert = XAlertTitle(@"Network Error", msg);
            [alert addAction:XAlertBtnHandler(@"Ok", handler)];
            dispatch_async(dispatch_get_main_queue(), ^{
              [self presentViewController:alert animated:YES completion:nil];
            });
          }

          [self hideActivityIndicator];
          });
        }] resume];
}

- (void)updatePushbulletDevices {
  NSDictionary* builtInServices =
      NSPushDictionaryValue(_prefs[NSPPreferenceBuiltInServicesKey]) ?: @{};
  NSDictionary* serviceObj =
      NSPushDictionaryValue(builtInServices[_service]) ?: @{};
  NSString* pushbulletToken =
      XStrDefault(serviceObj[NSPPreferenceServiceTokenKey], @"");
  NSMutableURLRequest* request = [NSMutableURLRequest
       requestWithURL:
           [NSURL URLWithString:@"https://api.pushbullet.com/v2/devices"]
          cachePolicy:NSURLRequestUseProtocolCachePolicy
      timeoutInterval:10];
  [request setHTTPMethod:@"GET"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  [request setValue:pushbulletToken forHTTPHeaderField:@"Access-Token"];

  // use async way to connect network
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response,
                            NSError* error) {
          // Run the whole response handling on the main thread: _serviceItems
          // is mutated here and read by the table view, so touching it from
          // NSURLSession's background queue races with cell rendering.
          dispatch_async(dispatch_get_main_queue(), ^{
          if (data.length && error == nil) {
            XLog(@"Success");
            NSError* jsonError = nil;
            NSDictionary* json = NSPJSONDictionary(
                [NSJSONSerialization JSONObjectWithData:data
                                               options:kNilOptions
                                                 error:&jsonError]);
            if (jsonError) {
              XLog(@"JSON Error: %@", jsonError);
            }

            NSDictionary* error =
                [json[@"error"] isKindOfClass:NSDictionary.class]
                    ? (NSDictionary*)json[@"error"]
                    : nil;
            if (error) {
              XLog(@"Something went wrong");
              NSString* title = @"Server Error";
              NSString* msg = error[@"message"] ?: @"Unknown Error";
              UIAlertController* alert = XAlertTitle(title, msg);
              id handler = ^(UIAlertAction* action) {
                [self.navigationController popViewControllerAnimated:YES];
              };
              [alert addAction:XAlertBtnHandler(@"Ok", handler)];
              dispatch_async(dispatch_get_main_queue(), ^{
                [self presentViewController:alert animated:YES completion:nil];
              });
              [self hideActivityIndicator];
              return;
            }

            id rawDevices = json[@"devices"];
            NSMutableArray* serviceDevices =
                [rawDevices isKindOfClass:NSArray.class]
                    ? [(NSArray*)rawDevices mutableCopy]
                    : [NSMutableArray new];

            NSMutableArray* serviceDevicesToRemove = [NSMutableArray new];
            for (NSDictionary* savedDevice in _serviceItems) {
              NSDictionary* foundNewDevice = nil;
              for (id rawNewDevice in serviceDevices) {
                if (![rawNewDevice isKindOfClass:NSDictionary.class]) {
                  continue;
                }
                NSDictionary* newDevice = (NSDictionary*)rawNewDevice;
                if (XEq(savedDevice[@"id"], newDevice[@"iden"])) {
                  foundNewDevice = newDevice;
                  break;
                }
              }
              if (foundNewDevice) {
                // prevent from adding later because already exists
                [serviceDevices removeObject:foundNewDevice];
              } else {
                [serviceDevicesToRemove addObject:savedDevice];
              }
            }

            for (id rawDevice in serviceDevices) {
              if (![rawDevice isKindOfClass:NSDictionary.class]) {
                continue;
              }
              NSDictionary* newDevice = (NSDictionary*)rawDevice;
              // pushable deprecated
              if (!NSPushBoolResolved(newDevice[@"active"], YES)) {
                continue;
              }
              id deviceID = newDevice[@"iden"];
              if (![deviceID isKindOfClass:NSString.class] ||
                  [(NSString*)deviceID length] == 0) {
                continue;
              }
              id rawName = newDevice[@"nickname"];
              if (![rawName isKindOfClass:NSString.class]) {
                rawName = newDevice[@"model"];
              }
              NSString* name = [rawName isKindOfClass:NSString.class]
                                   ? (NSString*)rawName
                                   : @"";
              [_serviceItems addObject:[@{
                               @"name" : name,
                               @"id" : deviceID,
                               @"enabled" : @NO
                             } mutableCopy]];
            }
            for (NSDictionary* savedDevice in serviceDevicesToRemove) {
              [_serviceItems removeObject:savedDevice];
            }

            [self saveServiceItems];

            XLog(@"Saved devices");

            // Reload specifiers on current screen
            dispatch_async(dispatch_get_main_queue(), ^{
              [self reloadSpecifiers];
            });

          } else {
            id handler = ^(UIAlertAction* action) {
              [self.navigationController popViewControllerAnimated:YES];
            };
            NSString* msg;
            if (data.length == 0 && error == nil) {
              msg = @"Server did not respond. Please check your internet "
                    @"connection or try again later.";
            } else if (error) {
              msg = error.localizedDescription;
            } else {
              msg = @"Unknown Error. Contact Developer.";
            }
            UIAlertController* alert = XAlertTitle(@"Network Error", msg);
            [alert addAction:XAlertBtnHandler(@"Ok", handler)];
            dispatch_async(dispatch_get_main_queue(), ^{
              [self presentViewController:alert animated:YES completion:nil];
            });
          }

          [self hideActivityIndicator];
          });
        }] resume];
}

- (void)updatePushbulletSounds {
  NSDictionary* builtInServices =
      NSPushDictionaryValue(_prefs[NSPPreferenceBuiltInServicesKey]) ?: @{};
  NSDictionary* serviceObj =
      NSPushDictionaryValue(builtInServices[_service]) ?: @{};
  NSString* pushbulletToken =
      XStrDefault(serviceObj[NSPPreferenceServiceTokenKey], @"");
  NSMutableURLRequest* request = [NSMutableURLRequest
       requestWithURL:[NSURL
                          URLWithString:@"https://api.pushbullet.com/v2/sounds"]
          cachePolicy:NSURLRequestUseProtocolCachePolicy
      timeoutInterval:10];
  [request setHTTPMethod:@"GET"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  [request setValue:pushbulletToken forHTTPHeaderField:@"Access-Token"];

  // use async way to connect network
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response,
                            NSError* error) {
          // Run the whole response handling on the main thread: _serviceItems
          // is mutated here and read by the table view, so touching it from
          // NSURLSession's background queue races with cell rendering.
          dispatch_async(dispatch_get_main_queue(), ^{
          if (data.length && error == nil) {
            XLog(@"Success");
            NSError* jsonError = nil;
            NSDictionary* json = NSPJSONDictionary(
                [NSJSONSerialization JSONObjectWithData:data
                                               options:kNilOptions
                                                 error:&jsonError]);
            if (jsonError) {
              XLog(@"JSON Error: %@", jsonError);
            }

            NSDictionary* error =
                [json[@"error"] isKindOfClass:NSDictionary.class]
                    ? (NSDictionary*)json[@"error"]
                    : nil;
            if (error) {
              XLog(@"Something went wrong");
              NSString* title = @"Server Error";
              NSString* msg = error[@"message"] ?: @"Unknown Error";
              UIAlertController* alert = XAlertTitle(title, msg);
              id handler = ^(UIAlertAction* action) {
                [self.navigationController popViewControllerAnimated:YES];
              };
              [alert addAction:XAlertBtnHandler(@"Ok", handler)];
              dispatch_async(dispatch_get_main_queue(), ^{
                [self presentViewController:alert animated:YES completion:nil];
              });
              [self hideActivityIndicator];
              return;
            }

            id rawSounds = json[@"sounds"];
            NSMutableArray* serviceSounds =
                [rawSounds isKindOfClass:NSArray.class]
                    ? [(NSArray*)rawSounds mutableCopy]
                    : [NSMutableArray new];

            NSMutableArray* serviceSoundsToRemove = [NSMutableArray new];
            for (NSDictionary* savedSound in _serviceItems) {
              NSDictionary* foundNewSound = nil;
              for (id rawNewSound in serviceSounds) {
                if (![rawNewSound isKindOfClass:NSDictionary.class]) {
                  continue;
                }
                NSDictionary* newSound = (NSDictionary*)rawNewSound;
                if (XEq(savedSound[@"id"], newSound[@"iden"])) {
                  foundNewSound = newSound;
                  break;
                }
              }
              if (foundNewSound) {
                // prevent from adding later because already exists
                [serviceSounds removeObject:foundNewSound];
              } else {
                [serviceSoundsToRemove addObject:savedSound];
              }
            }

            for (id rawSound in serviceSounds) {
              if (![rawSound isKindOfClass:NSDictionary.class]) {
                continue;
              }
              NSDictionary* newSound = (NSDictionary*)rawSound;
              // pushable deprecated
              if (!NSPushBoolResolved(newSound[@"active"], YES)) {
                continue;
              }
              id soundID = newSound[@"iden"];
              if (![soundID isKindOfClass:NSString.class] ||
                  [(NSString*)soundID length] == 0) {
                continue;
              }
              id rawName = newSound[@"nickname"];
              if (![rawName isKindOfClass:NSString.class]) {
                rawName = newSound[@"model"];
              }
              NSString* name = [rawName isKindOfClass:NSString.class]
                                   ? (NSString*)rawName
                                   : @"";
              [_serviceItems addObject:[@{
                               @"name" : name,
                               @"id" : soundID,
                               @"enabled" : @NO
                             } mutableCopy]];
            }
            for (NSDictionary* savedSound in serviceSoundsToRemove) {
              [_serviceItems removeObject:savedSound];
            }

            [self saveServiceItems];

            XLog(@"Saved sounds");

            // Reload specifiers on current screen
            dispatch_async(dispatch_get_main_queue(), ^{
              [self reloadSpecifiers];
            });

          } else {
            id handler = ^(UIAlertAction* action) {
              [self.navigationController popViewControllerAnimated:YES];
            };
            NSString* msg;
            if (data.length == 0 && error == nil) {
              msg = @"Server did not respond. Please check your internet "
                    @"connection or try again later.";
            } else if (error) {
              msg = error.localizedDescription;
            } else {
              msg = @"Unknown Error. Contact Developer.";
            }
            UIAlertController* alert = XAlertTitle(@"Network Error", msg);
            [alert addAction:XAlertBtnHandler(@"Ok", handler)];
            dispatch_async(dispatch_get_main_queue(), ^{
              [self presentViewController:alert animated:YES completion:nil];
            });
          }

          [self hideActivityIndicator];
          });
        }] resume];
}

@end
