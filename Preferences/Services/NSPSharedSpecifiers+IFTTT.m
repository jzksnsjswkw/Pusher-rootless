#import "../NSPSharedSpecifiers.h"
#import "../NSPLocalization.h"
#import "../NSPushServicePrefs.h"
#import "../../Generated/BuiltinServices.generated.h"
#import "../../global.h"

@implementation NSPSharedSpecifiers (IFTTT)

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

+ (void)load {
  [NSPushServicePrefsManager registerBuilder:^NSArray*(NSString* appID) {
    return [NSPSharedSpecifiers ifttt:appID];
  } forService:PUSHER_SERVICE_IFTTT];
}

@end