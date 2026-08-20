#import "../NSPSharedSpecifiers.h"
#import "../NSPLocalization.h"
#import "../NSPushServicePrefs.h"
#import "../NSPDeviceListController.h"
#import "../../Generated/BuiltinServices.generated.h"

@implementation NSPSharedSpecifiers (Pushbullet)

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

+ (void)load {
  [NSPushServicePrefsManager registerBuilder:^NSArray*(NSString* appID) {
    return [NSPSharedSpecifiers pushbullet:appID];
  } forService:PUSHER_SERVICE_PUSHBULLET];
}

@end