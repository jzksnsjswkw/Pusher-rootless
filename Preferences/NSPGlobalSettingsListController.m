#import "NSPGlobalSettingsListController.h"
#import "NSPSharedSpecifiers.h"

#import "../global.h"
#import "../helpers.h"
#import <notify.h>

@implementation NSPGlobalSettingsListController

- (NSArray *)specifiers {
  if (!_specifiers) {
    _specifiers =
        [[[[self loadSpecifiersFromPlistName:@"GlobalAppList" target:self]
            arrayByAddingObjectsFromArray:
                [self loadSpecifiersFromPlistName:@"GlobalAndServices"
                                           target:self]] mutableCopy] retain];

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

    for (PSSpecifier *specifier in _specifiers) {
      if (specifier.cellType == PSLinkCell &&
          XEq(specifier.name, @"Global App List")) {
        specifier.name =
            XStr(@"%@ (%d total)", specifier.name,
                 [NSPSharedSpecifiers
                     countAppIDsWithPrefix:
                         prefs
                                    prefix:[specifier
                                               propertyForKey:
                                                   @"ALSettingsKeyPrefix"]]);
        [specifier setProperty:self forKey:@"psListRef"];
        break;
      }
    }
  }

  return _specifiers;
}

@end
