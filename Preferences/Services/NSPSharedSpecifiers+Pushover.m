#import "../NSPSharedSpecifiers.h"
#import "../NSPLocalization.h"
#import "../NSPushServicePrefs.h"
#import "../NSPDeviceListController.h"
#import "../NSPSoundListController.h"
#import "../../Generated/BuiltinServices.generated.h"

@implementation NSPSharedSpecifiers (Pushover)

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

+ (void)load {
  [NSPushServicePrefsManager registerBuilder:^NSArray*(NSString* appID) {
    return [NSPSharedSpecifiers pushover:appID];
  } forService:PUSHER_SERVICE_PUSHOVER];
}

@end