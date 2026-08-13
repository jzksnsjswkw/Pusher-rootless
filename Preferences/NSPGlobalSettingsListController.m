#import "NSPGlobalSettingsListController.h"
#import "NSPSharedSpecifiers.h"

#import "../global.h"
#import "../helpers.h"
#import <notify.h>

@implementation NSPGlobalSettingsListController

- (NSArray*)specifiers {
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
    NSDictionary* prefs = @{};
    if (keyList) {
      // CFPreferencesCopyMultiple returns a +1 object. CFBridgingRelease is a no-op
      // under MRC, so autorelease the +1 explicitly (local var, used immediately).
      prefs = [(id)CFPreferencesCopyMultiple(
          keyList, PUSHER_APP_ID, kCFPreferencesCurrentUser,
          kCFPreferencesAnyHost) autorelease];
      if (!prefs) {
        prefs = @{};
      }
      CFRelease(keyList);
    }

    for (PSSpecifier* specifier in _specifiers) {
      if (specifier.cellType == PSLinkCell &&
          XEq(specifier.name, @"Global App List")) {
        specifier.name = XStr(
            @"%@ (%d total)", specifier.name,
            [NSPSharedSpecifiers
                countAppIDsWithPrefix:prefs
                               prefix:[specifier propertyForKey:
                                                     @"ALSettingsKeyPrefix"]]);
        // Non-retaining NSValue to avoid controller -> specifier -> controller
        // retain cycle.
        [specifier
            setProperty:[NSValue valueWithNonretainedObject:self]
                 forKey:@"psListRef"];
        break;
      }
    }
  }

  return _specifiers;
}

@end
