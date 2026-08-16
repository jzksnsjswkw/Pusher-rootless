#import "NSPDeviceListController.h"
#import "NSPLocalization.h"

#import "../Generated/BuiltinServices.generated.h"
#import "../global.h"
#import "../helpers.h"

@implementation NSPDeviceListController

- (BOOL)isSoundMode {
  return NO;
}

- (BOOL)onlyAllowOne {
  return XEq(_service, PUSHER_SERVICE_PUSHBULLET);
}

- (NSString*)footerText {
  if (XEq(_service, PUSHER_SERVICE_PUSHOVER)) {
    return NSPLocalizedString(@"Selecting none will forward push notifications to all devices.", nil);
  }
  if (XEq(_service, PUSHER_SERVICE_PUSHBULLET)) {
    return NSPLocalizedString(@"Pushbullet only allows one receiving device. Selecting none will "
                                 @"forward push notifications to all devices.", nil);
  }
  return nil;
}

- (void)updatePushoverItems {
  [self updatePushoverDevices];
}

- (void)updatePushbulletItems {
  [self updatePushbulletDevices];
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
            NSDictionary* json = NSPushDictionaryValue(
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
                title = NSPLocalizedString(@"Unknown Error", nil);
                msg = XStr(NSPLocalizedString(@"Server response: %@", nil), json);
              } else {
                title = NSPLocalizedString(@"Server Error", nil);
                msg = XStr(@"%@", [errors componentsJoinedByString:@"\n"]);
              }
              UIAlertController* alert = XAlertTitle(title, msg);
              id handler = ^(UIAlertAction* action) {
                [self.navigationController popViewControllerAnimated:YES];
              };
              [alert addAction:XAlertBtnHandler(NSPLocalizedString(@"Ok", nil), handler)];
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
              msg = NSPLocalizedString(@"Server did not respond. Please check your internet "
                                                @"connection or try again later.", nil);
            } else if (error) {
              msg = error.localizedDescription;
            } else {
              msg = NSPLocalizedString(@"Unknown Error. Contact Developer.", nil);
            }
            UIAlertController* alert = XAlertTitle(NSPLocalizedString(@"Network Error", nil), msg);
            [alert addAction:XAlertBtnHandler(NSPLocalizedString(@"Ok", nil), handler)];
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
            NSDictionary* json = NSPushDictionaryValue(
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
              NSString* title = NSPLocalizedString(@"Server Error", nil);
              NSString* msg = error[@"message"] ?: NSPLocalizedString(@"Unknown Error", nil);
              UIAlertController* alert = XAlertTitle(title, msg);
              id handler = ^(UIAlertAction* action) {
                [self.navigationController popViewControllerAnimated:YES];
              };
              [alert addAction:XAlertBtnHandler(NSPLocalizedString(@"Ok", nil), handler)];
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
              msg = NSPLocalizedString(@"Server did not respond. Please check your internet "
                                                @"connection or try again later.", nil);
            } else if (error) {
              msg = error.localizedDescription;
            } else {
              msg = NSPLocalizedString(@"Unknown Error. Contact Developer.", nil);
            }
            UIAlertController* alert = XAlertTitle(NSPLocalizedString(@"Network Error", nil), msg);
            [alert addAction:XAlertBtnHandler(NSPLocalizedString(@"Ok", nil), handler)];
            dispatch_async(dispatch_get_main_queue(), ^{
              [self presentViewController:alert animated:YES completion:nil];
            });
          }

          [self hideActivityIndicator];
          });
        }] resume];
}

@end
