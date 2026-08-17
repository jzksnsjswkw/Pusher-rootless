#import "NSPSharedSpecifiers.h"
#import "NSPLocalization.h"
#import "NSPSharedSpecifiers+ServiceBuilders.h"
#import "NSPDeviceListController.h"
#import "NSPSoundListController.h"

#import "../Generated/BuiltinServices.generated.h"
#import "../global.h"
#import "../helpers.h"

// Per-service specifier builders. Kept out of NSPSharedSpecifiers.m so the
// "which specifiers does service X show" knowledge lives next to each
// service's UI without bloating the shared storage layer.

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

+ (NSArray*)pushover:(NSString*)appID {
  PSSpecifier* devices =
      [PSSpecifier preferenceSpecifierNamed:NSPLocalizedString(@"Receiving Devices", nil)
                                     target:nil
                                        set:nil
                                        get:nil
                                     detail:NSPDeviceListController.class
                                       cell:PSLinkCell
                                       edit:nil];
  PSSpecifier* sounds =
      [PSSpecifier preferenceSpecifierNamed:NSPLocalizedString(@"Notification Sound", nil)
                                     target:nil
                                        set:nil
                                        get:nil
                                     detail:NSPSoundListController.class
                                       cell:PSLinkCell
                                       edit:nil];

  [devices setProperty:PUSHER_SERVICE_PUSHOVER forKey:@"service"];
  [sounds setProperty:PUSHER_SERVICE_PUSHOVER forKey:@"service"];

  BOOL isCustomApp = appID != nil;

  [devices setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [sounds setProperty:@(isCustomApp) forKey:@"isCustomApp"];

  [devices setProperty:@NO forKey:@"isSound"];
  [sounds setProperty:@YES forKey:@"isSound"];

  if (isCustomApp) {
    [devices setProperty:appID forKey:@"customAppIDKey"];
    [sounds setProperty:appID forKey:@"customAppIDKey"];
  }

  return @[ devices, sounds ];
}

+ (NSArray*)pushbullet:(NSString*)appID {
  PSSpecifier* devices =
      [PSSpecifier preferenceSpecifierNamed:NSPLocalizedString(@"Receiving Devices", nil)
                                     target:nil
                                        set:nil
                                        get:nil
                                     detail:NSPDeviceListController.class
                                       cell:PSLinkCell
                                       edit:nil];
  [devices setProperty:PUSHER_SERVICE_PUSHBULLET forKey:@"service"];
  BOOL isCustomApp = appID != nil;
  [devices setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [devices setProperty:@NO forKey:@"isSound"];
  if (isCustomApp) {
    [devices setProperty:appID forKey:@"customAppIDKey"];
  }
  return @[ devices ];
}

+ (NSArray*)ifttt:(NSString*)appID {
  BOOL isCustomApp = appID != nil;

  PSSpecifier* eventName = [PSSpecifier
      preferenceSpecifierNamed:NSPLocalizedString(@"Event Name", nil)
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [eventName setProperty:NSPPreferenceServiceEventNameKey forKey:@"key"];
  [eventName setProperty:@YES forKey:@"enabled"];
  [eventName setProperty:@YES forKey:@"noAutoCorrect"];
  [eventName setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [eventName setProperty:PUSHER_SERVICE_IFTTT forKey:@"service"];
  [eventName setProperty:@"eventName" forKey:@"customAppsPrefsKey"];

  PSSpecifier* includeIcon = [PSSpecifier
      preferenceSpecifierNamed:NSPLocalizedString(@"Include Icon", nil)
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSSwitchCell
                          edit:nil];
  [includeIcon setProperty:NSPPreferenceServiceIncludeIconKey forKey:@"key"];
  [includeIcon setProperty:@YES forKey:@"enabled"];
  [includeIcon setProperty:@NO forKey:@"default"];
  [includeIcon setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [includeIcon setProperty:PUSHER_SERVICE_IFTTT forKey:@"service"];
  [includeIcon setProperty:@"includeIcon" forKey:@"customAppsPrefsKey"];

  PSSpecifier* curateData = [PSSpecifier
      preferenceSpecifierNamed:NSPLocalizedString(@"Curate Request Data", nil)
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSSwitchCell
                          edit:nil];
  [curateData setProperty:NSPPreferenceServiceCurateDataKey forKey:@"key"];
  [curateData setProperty:@YES forKey:@"enabled"];
  [curateData setProperty:@YES forKey:@"default"];
  [curateData setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [curateData setProperty:PUSHER_SERVICE_IFTTT forKey:@"service"];
  [curateData setProperty:@"curateData" forKey:@"customAppsPrefsKey"];

  if (isCustomApp) {
    [eventName setProperty:appID forKey:@"customAppID"];
    [includeIcon setProperty:appID forKey:@"customAppID"];
    [curateData setProperty:appID forKey:@"customAppID"];
  }

  return @[ eventName, includeIcon, curateData ];
}

+ (NSArray*)wechat:(NSString*)appID {
  BOOL isCustomApp = appID != nil;

  PSSpecifier* touser = [PSSpecifier
      preferenceSpecifierNamed:NSPLocalizedString(@"Touser", nil)
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [touser setProperty:NSPPreferenceServiceTouserKey forKey:@"key"];
  [touser setProperty:@YES forKey:@"enabled"];
  [touser setProperty:@YES forKey:@"noAutoCorrect"];
  [touser setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [touser setProperty:PUSHER_SERVICE_WECHAT forKey:@"service"];
  [touser setProperty:@"touser" forKey:@"customAppsPrefsKey"];

  if (isCustomApp) {
    [touser setProperty:appID forKey:@"customAppID"];
  }

  return @[ touser ];
}

+ (NSArray*)bark:(NSString*)appID {
  BOOL isCustomApp = appID != nil;

  NSArray<NSDictionary*>* fields = @[
    @{@"label" : @"Level:", @"key" : NSPPreferenceBarkLevelKey},
    @{@"label" : @"Volume:", @"key" : NSPPreferenceBarkVolumeKey},
    @{@"label" : @"Badge:", @"key" : NSPPreferenceBarkBadgeKey},
    @{@"label" : @"Call:", @"key" : NSPPreferenceBarkCallKey},
    @{@"label" : @"AutoCopy:", @"key" : NSPPreferenceBarkAutoCopyKey},
    @{@"label" : @"Sound:", @"key" : NSPPreferenceBarkSoundKey},
    @{@"label" : @"Image:", @"key" : NSPPreferenceBarkImageKey},
    @{@"label" : @"Group:", @"key" : NSPPreferenceBarkGroupKey},
    @{@"label" : @"IsArchive:", @"key" : NSPPreferenceBarkIsArchiveKey},
    @{@"label" : @"TTL:", @"key" : NSPPreferenceBarkTTLKey},
    @{@"label" : @"URL:", @"key" : NSPPreferenceBarkClickURLKey},
    @{@"label" : @"Action:", @"key" : NSPPreferenceBarkActionKey},
    @{@"label" : @"ID:", @"key" : NSPPreferenceBarkIDKey},
    @{@"label" : @"Delete:", @"key" : NSPPreferenceBarkDeleteKey}
  ];

  NSMutableArray* specifiers = [NSMutableArray new];
  for (NSDictionary* field in fields) {
    NSString* prefKey = field[@"key"];
    PSSpecifier* specifier = [PSSpecifier
        preferenceSpecifierNamed:NSPLocalizedString(field[@"label"], nil)
                          target:self
                             set:@selector(setPreferenceValue:
                                           forBuiltInServiceSpecifier:)
                             get:@selector(readBuiltInServicePreferenceValue:)
                          detail:nil
                            cell:PSEditTextCell
                            edit:nil];
    [specifier setProperty:prefKey forKey:@"key"];
    [specifier setProperty:@YES forKey:@"enabled"];
    [specifier setProperty:@YES forKey:@"noAutoCorrect"];
    [specifier setProperty:@(isCustomApp) forKey:@"isCustomApp"];
    [specifier setProperty:PUSHER_SERVICE_BARK forKey:@"service"];
    [specifier setProperty:prefKey forKey:@"customAppsPrefsKey"];
    if (isCustomApp) {
      [specifier setProperty:appID forKey:@"customAppID"];
    }
    [specifiers addObject:specifier];
  }
  return specifiers;
}

+ (NSArray*)pusherReceiver:(NSString*)appID {
  BOOL isCustomApp = appID != nil;

  PSSpecifier* includeIcon = [PSSpecifier
      preferenceSpecifierNamed:NSPLocalizedString(@"Include Icon", nil)
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSSwitchCell
                          edit:nil];
  [includeIcon setProperty:NSPPreferenceServiceIncludeIconKey forKey:@"key"];
  [includeIcon setProperty:@YES forKey:@"enabled"];
  [includeIcon setProperty:@YES forKey:@"default"];
  [includeIcon setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [includeIcon setProperty:PUSHER_SERVICE_PUSHER_RECEIVER forKey:@"service"];
  [includeIcon setProperty:@"includeIcon" forKey:@"customAppsPrefsKey"];

  PSSpecifier* includeImage = [PSSpecifier
      preferenceSpecifierNamed:NSPLocalizedString(@"Include Image", nil)
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSSwitchCell
                          edit:nil];
  [includeImage setProperty:NSPPreferenceServiceIncludeImageKey forKey:@"key"];
  [includeImage setProperty:@YES forKey:@"enabled"];
  [includeImage setProperty:@YES forKey:@"default"];
  [includeImage setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [includeImage setProperty:PUSHER_SERVICE_PUSHER_RECEIVER forKey:@"service"];
  [includeImage setProperty:@"includeImage" forKey:@"customAppsPrefsKey"];

  PSSpecifier* imageMaxWidth = [PSSpecifier
      preferenceSpecifierNamed:NSPLocalizedString(@"Maximum Image Width (pixels)", nil)
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [imageMaxWidth setProperty:NSPPreferenceServiceImageMaxWidthKey
                      forKey:@"key"];
  [imageMaxWidth setProperty:@YES forKey:@"enabled"];
  [imageMaxWidth setProperty:@YES forKey:@"isDecimalPad"];
  [imageMaxWidth setProperty:@(PUSHER_DEFAULT_MAX_WIDTH) forKey:@"default"];
  [imageMaxWidth setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [imageMaxWidth setProperty:PUSHER_SERVICE_PUSHER_RECEIVER forKey:@"service"];
  [imageMaxWidth setProperty:@"imageMaxWidth" forKey:@"customAppsPrefsKey"];

  PSSpecifier* imageMaxHeight = [PSSpecifier
      preferenceSpecifierNamed:NSPLocalizedString(@"Maximum Image Height (pixels)", nil)
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [imageMaxHeight setProperty:NSPPreferenceServiceImageMaxHeightKey
                       forKey:@"key"];
  [imageMaxHeight setProperty:@YES forKey:@"enabled"];
  [imageMaxHeight setProperty:@YES forKey:@"isDecimalPad"];
  [imageMaxHeight setProperty:@(PUSHER_DEFAULT_MAX_HEIGHT) forKey:@"default"];
  [imageMaxHeight setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [imageMaxHeight setProperty:PUSHER_SERVICE_PUSHER_RECEIVER forKey:@"service"];
  [imageMaxHeight setProperty:@"imageMaxHeight" forKey:@"customAppsPrefsKey"];

  PSSpecifier* imageShrinkFactor = [PSSpecifier
      preferenceSpecifierNamed:NSPLocalizedString(@"Image Shrink Factor Upon Retry", nil)
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [imageShrinkFactor setProperty:NSPPreferenceServiceImageShrinkFactorKey
                          forKey:@"key"];
  [imageShrinkFactor setProperty:@YES forKey:@"enabled"];
  [imageShrinkFactor setProperty:@YES forKey:@"isDecimalPad"];
  [imageShrinkFactor setProperty:@(PUSHER_DEFAULT_SHRINK_FACTOR)
                          forKey:@"default"];
  [imageShrinkFactor setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [imageShrinkFactor setProperty:PUSHER_SERVICE_PUSHER_RECEIVER
                          forKey:@"service"];
  [imageShrinkFactor setProperty:@"imageShrinkFactor"
                          forKey:@"customAppsPrefsKey"];

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

@end
