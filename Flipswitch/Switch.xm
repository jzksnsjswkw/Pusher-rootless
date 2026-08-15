#import "FSSwitchDataSource.h"
#import "FSSwitchPanel.h"

#import "../global.h"
#import "../helpers.h"

@interface NSUserDefaults (Tweak_Category)
- (id)objectForKey:(NSString*)key inDomain:(NSString*)domain;
- (void)setObject:(id)value forKey:(NSString*)key inDomain:(NSString*)domain;
@end

@interface PusherSwitch : NSObject <FSSwitchDataSource>
@end

@implementation PusherSwitch

- (NSString*)titleForSwitchIdentifier:(NSString*)switchIdentifier {
  return kName;
}

- (FSSwitchState)stateForSwitchIdentifier:(NSString*)switchIdentifier {
  id n = [[NSUserDefaults standardUserDefaults]
      objectForKey:@"Enabled"
          inDomain:(__bridge NSString*)PUSHER_APP_ID];
  // Guard against hand-edited/malformed prefs: only NSNumber/NSString have a
  // safe boolValue, anything else falls back to the default enabled state.
  BOOL enabled = NSPushBoolResolved(n, YES);
  return enabled ? FSSwitchStateOn : FSSwitchStateOff;
}

- (void)applyState:(FSSwitchState)newState
    forSwitchIdentifier:(NSString*)switchIdentifier {
  switch (newState) {
  case FSSwitchStateIndeterminate:
    break;
  default:
    [[NSUserDefaults standardUserDefaults]
        setObject:@(newState == FSSwitchStateOn)
           forKey:@"Enabled"
         inDomain:(__bridge NSString*)PUSHER_APP_ID];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(PUSHER_PREFS_NOTIFICATION), NULL, NULL, YES);
    break;
  }
  return;
}

@end
