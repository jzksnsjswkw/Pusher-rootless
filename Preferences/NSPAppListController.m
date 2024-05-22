#import "NSPAppListController.h"
#include <Foundation/Foundation.h>

#import "../global.h"
#import "../helpers.h"
#import <notify.h>

@implementation NSPAppListController
- (void)viewDidLoad {
  [super viewDidLoad];

  _prefix = [self.specifier propertyForKey:@"ALSettingsKeyPrefix"];
}

- (void)loadPreferences {
  // Get preferences
  CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);
  CFArrayRef keyList = CFPreferencesCopyKeyList(
      PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  NSDictionary *_prefs = @{};
  _selectedApplications = [NSMutableSet new];
  if (keyList) {
    _prefs = (NSDictionary *)CFPreferencesCopyMultiple(
        keyList, PUSHER_APP_ID, kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost);
    if (!_prefs) {
      _prefs = @{};
    }
    CFRelease(keyList);
  }
  _prefix = [self.specifier propertyForKey:@"ALSettingsKeyPrefix"];
  for (id key in _prefs.allKeys) {
    if (![key isKindOfClass:NSString.class]) {
      continue;
    }
    if ([key hasPrefix:_prefix] && ((NSNumber *)_prefs[key]).boolValue) {
      NSString *subKey = [key substringFromIndex:_prefix.length];
      [_selectedApplications addObject:subKey];
    }
  }
  NSLog(@"%@", _selectedApplications);
}

- (void)setApplicationEnabled:(NSNumber *)enabledNum
                    specifier:(PSSpecifier *)specifier {
  NSString *appID = [specifier propertyForKey:@"applicationIdentifier"];
  if ([enabledNum boolValue] != _defaultApplicationSwitchValue) {
    [_selectedApplications addObject:appID];
  } else {
    [_selectedApplications removeObject:appID];
  }

  NSString *key = XStr(@"%@%@", _prefix, appID);
  CFPreferencesSetValue((__bridge CFStringRef)key, @([enabledNum boolValue]),
                        PUSHER_APP_ID, kCFPreferencesCurrentUser,
                        kCFPreferencesAnyHost);
  CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);
  notify_post(PUSHER_PREFS_NOTIFICATION);
}
@end
