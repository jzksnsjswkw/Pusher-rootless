#import "../NSPSharedSpecifiers.h"
#import "../NSPLocalization.h"
#import "../NSPushServicePrefs.h"
#import "../../Generated/BuiltinServices.generated.h"
#import "../../global.h"

@implementation NSPSharedSpecifiers (Bark)

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

+ (void)load {
  [NSPushServicePrefsManager registerBuilder:^NSArray*(NSString* appID) {
    return [NSPSharedSpecifiers bark:appID];
  } forService:PUSHER_SERVICE_BARK];
}

@end