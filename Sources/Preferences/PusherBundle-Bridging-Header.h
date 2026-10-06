// Bridging header for the Preferences bundle.
//
// This bundle compiles the whole Core pipeline (so the UI and the tweak read
// prefs through the same code) plus the settings UI, so it imports both the
// tweak's header and the two frameworks only the UI needs.
//
// Neither framework ships a module map, so neither can be `import`ed from Swift:
// their headers come in here and Swift subclasses the ObjC classes directly.

#import "../Hooks/Pusher-Bridging-Header.h"

// The Preferences framework's specifier/controller classes.
#import <Preferences/PSListController.h>
#import <Preferences/PSViewController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSListItemsController.h>

// AltList enumerates installed apps for the app pickers.
#import <AltList/AltList.h>

// `LSApplicationProxy` resolves an app's display name and bundle ID.
#import <MobileCoreServices/LSApplicationProxy.h>

// The distributed-messaging centre the "Send Test Notification" button uses to
// ask SpringBoard to run a push through the real pipeline.
#import <AppSupport/CPDistributedMessagingCenter.h>

// `PSSpecifier` declares `SEL setter; SEL getter;` as @public ivars. Swift does
// not import ObjC ivars, so they are read and written through the runtime; this
// is the declaration those accesses rely on.
@interface PSSpecifier (PusherIvars)
@end

#pragma mark - Preferences categories the UI relies on

/// `PSTableCell` exposes its icon view only through this private accessor, which
/// is what the tinting code recolors.
@interface PSTableCell (Pusher)
- (UIImageView *)iconImageView;
@end

/// `PSSpecifier` has no public way to set a segment/radio cell's choices; the
/// Preferences framework uses this one internally, and the plists' `validTitles`
/// / `validValues` pairs are handed to it.
@interface PSSpecifier (PusherValues)
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
- (void)performSetterWithValue:(id)value;
@end

/// `PSListController` pushes detail controllers through this method.
@interface PSListController (PusherNavigation)
- (void)pushController:(UIViewController *)controller;
@end

// `CPDistributedMessagingCenter`'s public header declares the reply variants
// with a trailing `error:` parameter, and Swift imports those under the
// `sendMessageAndReceiveReply(name:userInfo:error:)` name. The reply itself is
// the test push's success flag.
