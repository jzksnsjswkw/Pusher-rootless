#import "NSPushLogStore.h"
#import "../Core/NSPushConstants.h"
#import "../helpers.h"
#import <notify.h>

@implementation NSPushLogStore

+ (NSDictionary*)snapshot {
  CFPreferencesSynchronize(PUSHER_LOG_ID, kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);
  CFArrayRef keyList = CFPreferencesCopyKeyList(
      PUSHER_LOG_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  NSDictionary* prefs = @{};
  if (keyList) {
    prefs = (__bridge_transfer NSDictionary*)CFPreferencesCopyMultiple(
        keyList, PUSHER_LOG_ID, kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost);
    if (!prefs) {
      prefs = @{};
    }
    CFRelease(keyList);
  }
  return prefs;
}

+ (NSArray*)logSectionsForService:(NSString*)service {
  if (![service isKindOfClass:NSString.class]) {
    service = @"";
  }
  return NSPushArrayValue([self snapshot][XStr(@"%@Log", service)]) ?: @[];
}

+ (void)setLogSections:(NSArray*)logSections
            forService:(NSString*)service
          shouldNotify:(BOOL)shouldNotify {
  if (![service isKindOfClass:NSString.class]) {
    service = @"";
  }
  NSString* logKey = XStr(@"%@Log", service);
  CFPreferencesSetValue((__bridge CFStringRef)logKey,
                        (__bridge CFPropertyListRef)logSections, PUSHER_LOG_ID,
                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  CFPreferencesSynchronize(PUSHER_LOG_ID, kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);
  if (shouldNotify) {
    notify_post(PUSHER_LOG_PREFS_NOTIFICATION);
  }
}

+ (void)removeLogsForService:(NSString*)service {
  if (![service isKindOfClass:NSString.class]) {
    service = @"";
  }
  CFPreferencesSetValue((__bridge CFStringRef)XStr(@"%@Log", service), NULL,
                        PUSHER_LOG_ID, kCFPreferencesCurrentUser,
                        kCFPreferencesAnyHost);
  CFPreferencesSynchronize(PUSHER_LOG_ID, kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);
}

+ (void)removeAllLogs {
  NSDictionary* prefs = [self snapshot];
  for (id key in prefs.allKeys) {
    if (![key isKindOfClass:NSString.class] ||
        ![(NSString*)key hasSuffix:@"Log"]) {
      continue;
    }
    CFPreferencesSetValue((__bridge CFStringRef)key, NULL, PUSHER_LOG_ID,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  }
  if (prefs.count > 0) {
    CFPreferencesSynchronize(PUSHER_LOG_ID, kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
  }
}

@end