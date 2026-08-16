#import "../global.h"
#import "NSPPSListControllerWithColoredUI.h"

@interface NSPDeviceSoundListController : NSPPSListControllerWithColoredUI {
  NSMutableArray* _serviceItems;
  NSDictionary* _prefs;
  UIBarButtonItem* _updateBn;
  UIActivityIndicatorView* _activityIndicator;
  UIBarButtonItem* _activityIndicatorBn;
  NSString* _prefsKey;
  NSString* _service;
  BOOL _isSound;
  BOOL _isCustomApp;
  NSString* _customAppIDKey;
  BOOL _onlyAllowOne;
}
- (void)setPreferenceValue:(id)value forItemSpecifier:(PSSpecifier*)specifier;
- (id)readItemPreferenceValue:(PSSpecifier*)specifier;
- (void)updateItems;
- (void)showActivityIndicator;
- (void)hideActivityIndicator;
// Subclass hooks.
- (BOOL)isSoundMode;
- (NSString*)storageKey;
- (BOOL)onlyAllowOne;
- (NSString*)footerText;
- (void)updatePushoverItems;
- (void)updatePushbulletItems;
- (void)saveServiceItems;
- (NSArray*)sortedItemList:(NSArray*)items;
@end
