#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "NSPRootListController.h"

// Localized string helper for the Preferences bundle.
//
// The bundle is loaded into the Preferences app, so NSLocalizedString (which
// looks in the main bundle) is not sufficient.  This resolves the current
// bundle from the principal controller class and looks up the key in the
// bundle's Localizable.strings table.  When no translation exists, the key
// itself is returned, so English remains the fallback.
NS_INLINE NSString* NSPLocalizedString(NSString* key, NSString* comment) {
  if (![key isKindOfClass:NSString.class]) {
    return @"";
  }
  static NSBundle* bundle = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    bundle = [NSBundle bundleForClass:NSPRootListController.class];
  });
  return [bundle localizedStringForKey:key value:key table:nil];
}

// Human-readable display name for a built-in service.  Internal service keys
// (e.g. "Feishu", "Wechat") stay English in preferences/log storage, but the
// UI can show localized names.  Custom service names pass through unchanged.
NS_INLINE NSString* NSPushServiceDisplayName(NSString* service) {
  return NSPLocalizedString(
      [service isKindOfClass:NSString.class] ? service : @"", nil);
}
