#import "NSPSharedSpecifiers.h"
#import "NSPLocalization.h"
#import "NSPSharedSpecifiers+ServiceBuilders.h"
#import "../global.h"

// Shared specifiers for custom services. Built-in services no longer live
// here: each one self-registers its own builder in a dedicated
// NSPSharedSpecifiers+<Service>.m file (see NSPushServicePrefs.h).

@implementation NSPSharedSpecifiers (ServiceBuilders)

+ (NSArray*)getCustomShared:(NSString*)service withAppID:(NSString*)appID {
  BOOL isCustomApp = appID != nil;

  PSSpecifier* includeIcon = [PSSpecifier
      preferenceSpecifierNamed:NSPLocalizedString(@"Include Icon", nil)
                        target:self
                           set:@selector(setPreferenceValue:forCustomSpecifier:)
                           get:@selector(readCustomPreferenceValue:)
                        detail:nil
                          cell:PSSwitchCell
                          edit:nil];
  [includeIcon setProperty:@"includeIcon" forKey:@"key"];
  [includeIcon setProperty:@YES forKey:@"enabled"];
  [includeIcon setProperty:@NO forKey:@"default"];
  [includeIcon setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [includeIcon setProperty:service forKey:@"service"];

  PSSpecifier* includeImage = [PSSpecifier
      preferenceSpecifierNamed:NSPLocalizedString(@"Include Image", nil)
                        target:self
                           set:@selector(setPreferenceValue:forCustomSpecifier:)
                           get:@selector(readCustomPreferenceValue:)
                        detail:nil
                          cell:PSSwitchCell
                          edit:nil];
  [includeImage setProperty:@"includeImage" forKey:@"key"];
  [includeImage setProperty:@YES forKey:@"enabled"];
  [includeImage setProperty:@NO forKey:@"default"];
  [includeImage setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [includeImage setProperty:service forKey:@"service"];

  PSSpecifier* imageMaxWidth = [PSSpecifier
      preferenceSpecifierNamed:NSPLocalizedString(@"Maximum Image Width (pixels)", nil)
                        target:self
                           set:@selector(setPreferenceValue:forCustomSpecifier:)
                           get:@selector(readCustomPreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [imageMaxWidth setProperty:@"imageMaxWidth" forKey:@"key"];
  [imageMaxWidth setProperty:@YES forKey:@"enabled"];
  [imageMaxWidth setProperty:@YES forKey:@"isDecimalPad"];
  [imageMaxWidth setProperty:@(PUSHER_DEFAULT_MAX_WIDTH) forKey:@"default"];
  [imageMaxWidth setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [imageMaxWidth setProperty:service forKey:@"service"];

  PSSpecifier* imageMaxHeight = [PSSpecifier
      preferenceSpecifierNamed:NSPLocalizedString(@"Maximum Image Height (pixels)", nil)
                        target:self
                           set:@selector(setPreferenceValue:forCustomSpecifier:)
                           get:@selector(readCustomPreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [imageMaxHeight setProperty:@"imageMaxHeight" forKey:@"key"];
  [imageMaxHeight setProperty:@YES forKey:@"enabled"];
  [imageMaxHeight setProperty:@YES forKey:@"isDecimalPad"];
  [imageMaxHeight setProperty:@(PUSHER_DEFAULT_MAX_HEIGHT) forKey:@"default"];
  [imageMaxHeight setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [imageMaxHeight setProperty:service forKey:@"service"];

  PSSpecifier* imageShrinkFactor = [PSSpecifier
      preferenceSpecifierNamed:NSPLocalizedString(@"Image Shrink Factor Upon Retry", nil)
                        target:self
                           set:@selector(setPreferenceValue:forCustomSpecifier:)
                           get:@selector(readCustomPreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [imageShrinkFactor setProperty:@"imageShrinkFactor" forKey:@"key"];
  [imageShrinkFactor setProperty:@YES forKey:@"enabled"];
  [imageShrinkFactor setProperty:@YES forKey:@"isDecimalPad"];
  [imageShrinkFactor setProperty:@(PUSHER_DEFAULT_SHRINK_FACTOR)
                          forKey:@"default"];
  [imageShrinkFactor setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [imageShrinkFactor setProperty:service forKey:@"service"];

  if (isCustomApp) {
    [includeIcon setProperty:appID forKey:@"customAppID"];
    [includeImage setProperty:appID forKey:@"customAppID"];
    [imageMaxWidth setProperty:appID forKey:@"customAppID"];
    [imageMaxHeight setProperty:appID forKey:@"customAppID"];
    [imageShrinkFactor setProperty:appID forKey:@"customAppID"];
  }

  return @[
    includeIcon, includeImage, imageMaxWidth, imageMaxHeight, imageShrinkFactor
  ];
}

+ (NSArray*)getCustomShared:(NSString*)service {
  return [NSPSharedSpecifiers getCustomShared:service withAppID:nil];
}

@end