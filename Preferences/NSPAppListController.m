#import "NSPAppListController.h"
#include <Foundation/Foundation.h>

#import "../global.h"
#import "../helpers.h"
#import "NSPSharedSpecifiers.h"
#import <notify.h>

@implementation NSPAppListController
- (void)viewDidLoad {
  [super viewDidLoad];

  _prefix = [self.specifier propertyForKey:@"ALSettingsKeyPrefix"];
  _service = [self.specifier propertyForKey:@"service"];
  _isCustomService =
      [self.specifier propertyForKey:@"isCustomService"] &&
      ((NSNumber*)[self.specifier propertyForKey:@"isCustomService"]).boolValue;
}

- (void)loadPreferences {
  // Get preferences
  CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);
  CFArrayRef keyList = CFPreferencesCopyKeyList(
      PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  // Local variable (not an ivar), named prefs to avoid shadowing confusion.
  NSDictionary* prefs = @{};
  _selectedApplications = [NSMutableSet new];
  if (keyList) {
    prefs = (__bridge_transfer NSDictionary*)CFPreferencesCopyMultiple(
        keyList, PUSHER_APP_ID, kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost);
    if (!prefs) {
      prefs = @{};
    }
    CFRelease(keyList);
  }
  _prefix = [self.specifier propertyForKey:@"ALSettingsKeyPrefix"];
  _service = [self.specifier propertyForKey:@"service"];
  _isCustomService =
      [self.specifier propertyForKey:@"isCustomService"] &&
      ((NSNumber*)[self.specifier propertyForKey:@"isCustomService"]).boolValue;
  // Built-in and custom services store their app list as an array inside the
  // service object (no ALSettingsKeyPrefix). Only the global app list uses the
  // flat prefixed-key scheme.
  if (_service && !_prefix) {
    NSArray* appList = _isCustomService
                           ? [NSPSharedSpecifiers
                                 customServiceAppListForService:_service]
                           : [NSPSharedSpecifiers
                                 builtInServiceAppListForService:_service];
    [_selectedApplications addObjectsFromArray:appList];
  } else {
    for (id key in prefs.allKeys) {
      if (![key isKindOfClass:NSString.class]) {
        continue;
      }
      if ([key hasPrefix:_prefix] && ((NSNumber*)prefs[key]).boolValue) {
        NSString* subKey = [key substringFromIndex:_prefix.length];
        [_selectedApplications addObject:subKey];
      }
    }
  }
}

- (void)setApplicationEnabled:(NSNumber*)enabledNum
                    specifier:(PSSpecifier*)specifier {
  NSString* appID = [specifier propertyForKey:@"applicationIdentifier"];
  if ([enabledNum boolValue] != _defaultApplicationSwitchValue) {
    [_selectedApplications addObject:appID];
  } else {
    [_selectedApplications removeObject:appID];
  }

  if (_service && !_prefix) {
    if (_isCustomService) {
      [NSPSharedSpecifiers
          setCustomServiceAppList:_selectedApplications.allObjects
                       forService:_service];
    } else {
      [NSPSharedSpecifiers
          setBuiltInServiceAppList:_selectedApplications.allObjects
                        forService:_service];
    }
  } else {
    NSString* key = XStr(@"%@%@", _prefix, appID);
    CFPreferencesSetValue((__bridge CFStringRef)key,
                          (__bridge CFNumberRef) @([enabledNum boolValue]),
                          PUSHER_APP_ID, kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
    notify_post(PUSHER_PREFS_NOTIFICATION);
  }
}
@end
