#import "NSPSoundListController.h"
#import "NSPLocalization.h"

#import "../Generated/BuiltinServices.generated.h"
#import "../global.h"
#import "../helpers.h"

@implementation NSPSoundListController

- (BOOL)isSoundMode {
  return YES;
}

- (BOOL)onlyAllowOne {
  return YES;
}

- (void)updatePushoverItems {
  [self updatePushoverSounds];
}

- (void)updatePushbulletItems {
  [self updatePushbulletSounds];
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
