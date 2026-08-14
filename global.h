// Shared umbrella header for the tweak / Preferences / Flipswitch layers.
// Everything the Core push pipeline needs has moved into Core/NSPushConstants.h
// and Core/NSPBBServer.h; this file only keeps the UI-side constants and
// categories that are specific to the tweak and Preferences layers, and it no
// longer pulls in Preferences classes (NSPusherManager) so Core stays
// independent of the UI layer.

#import <Foundation/Foundation.h>
#import <roothide.h>

#import "Core/NSPushConstants.h"
#import "Core/NSPBBServer.h"

#define PUSHER_PREFS_FILE                                                      \
  jbroot(@"/var/mobile/Library/Preferences/com.noahsaso.pusher.plist")
#define PUSHER_BUNDLE_PATH jbroot(@"/Library/PreferenceBundles/Pusher.bundle")
#define PUSHER_BUNDLE [NSBundle bundleWithPath:PUSHER_BUNDLE_PATH]
#define PUSHER_COLOR                                                           \
  [UIColor colorWithRed:0.0 green:177 / 255.0 blue:79 / 255.0 alpha:1.0]

#define CURRENT_TINT_COLOR_KEY @"CurrentTintColor"

#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>

@interface PSSpecifier (Pusher)
@property(nonatomic, retain) NSArray* values;
- (void)performSetterWithValue:(id)arg1;
- (BOOL)hasValidSetter;
- (void)setValues:(id)arg1 titles:(id)arg2;
@end

@interface PSTableCell (Pusher)
- (UIImageView*)iconImageView;
@end

@interface UIView (Pusher)
- (id)_viewDelegate;
@end

@interface UIImage (Pusher)
+ (UIImage*)imageNamed:(NSString*)name inBundle:(NSBundle*)bundle;
@end