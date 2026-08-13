#import "NSPushLog.h"
#import "global.h"
#import "helpers.h"
#import <notify.h>

@interface NSPushLog (Private)
+ (NSString*)stringForObject:(id)object
                  withPrefix:(NSString*)prefix
                dontTruncate:(BOOL)dontTruncate;
+ (void)addToLogLockedForService:(NSString*)service
                       bulletin:(BBBulletin*)bulletin
                          label:(NSString*)label
                         object:(id)object
                   dontTruncate:(BOOL)dontTruncate;
@end

@implementation NSPushLog

+ (NSString*)stringForObject:(id)object
                  withPrefix:(NSString*)prefix
                dontTruncate:(BOOL)dontTruncate {
  NSString* str = @"";
  if (!object) {
    str = XStr(@"%@nil", prefix);
  } else if ([object isKindOfClass:NSArray.class]) {
    NSArray* array = (NSArray*)object;
    str = @"[";
    for (id val in array) {
      str = XStr(@"%@\n%@\t%@", str, prefix,
                 [NSPushLog stringForObject:val
                                 withPrefix:XStr(@"%@\t", prefix)
                               dontTruncate:dontTruncate]);
    }
    str = XStr(@"%@\n%@]", str, prefix);
  } else if ([object isKindOfClass:NSDictionary.class]) {
    NSDictionary* dict = (NSDictionary*)object;
    str = @"{";
    for (id key in dict.allKeys) {
      str = XStr(@"%@\n%@\t%@: %@", str, prefix, key,
                 [NSPushLog stringForObject:dict[key]
                                 withPrefix:XStr(@"%@\t", prefix)
                               dontTruncate:dontTruncate]);
    }
    str = XStr(@"%@\n%@}", str, prefix);
  } else {
    if (!dontTruncate && [object isKindOfClass:NSString.class] &&
        ((NSString*)object).length > PUSHER_LOG_MAX_STRING_LENGTH) {
      object =
          XStr(@"%@...", [(NSString*)object
                             substringToIndex:PUSHER_LOG_MAX_STRING_LENGTH]);
    }
    str = XStr(@"%@%@", prefix, object);
  }
  return str;
}

+ (NSString*)stringForObject:(id)object dontTruncate:(BOOL)dontTruncate {
  return [NSPushLog stringForObject:object
                         withPrefix:@""
                       dontTruncate:dontTruncate];
}

+ (NSString*)stringForObject:(id)object {
  return [NSPushLog stringForObject:object dontTruncate:NO];
}

+ (void)addToLogIfEnabledForService:(NSString*)service
                           bulletin:(BBBulletin*)bulletin
                              label:(NSString*)label
                             object:(id)object
                       dontTruncate:(BOOL)dontTruncate {
  // addToLogIfEnabledForService: can be reached concurrently from the main
  // thread and from NSURLSession background completion queues (e.g. the WeChat
  // service's token request); the read-modify-write of the log prefs must be
  // serialized or log entries can be lost.
  @synchronized(NSPushLog.class) {
    [NSPushLog addToLogLockedForService:service
                               bulletin:bulletin
                                  label:label
                                 object:object
                           dontTruncate:dontTruncate];
  }
}

+ (void)addToLogLockedForService:(NSString*)service
                        bulletin:(BBBulletin*)bulletin
                           label:(NSString*)label
                          object:(id)object
                    dontTruncate:(BOOL)dontTruncate {
  // allow global service which is @"" so empty
  if (!XIsEmpty(service)) {
    id val = CFBridgingRelease(CFPreferencesCopyAppValue(
        (__bridge CFStringRef)XStr(@"%@LogEnabled", service), PUSHER_APP_ID));
    BOOL logEnabled = val ? ((NSNumber*)val).boolValue : YES;
    if (!logEnabled) {
      XLog(@"[S:%@] Log Disabled", service);
      return;
    }
  }

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

  NSString* logKey = XStr(@"%@Log", service);
  NSMutableArray* logSections = [(prefs[logKey] ?: @[]) mutableCopy];

  NSString* currBulletinID = bulletin.bulletinID ?: @"empty_bulletin_id";
  NSString* currSectionID = bulletin.sectionID ?: @"empty_app_id";
  NSMutableDictionary* existingLogSection = nil;
  int replaceIdx = -1;
  for (int i = 0; i < logSections.count; i++) {
    NSDictionary* logSection = logSections[i];
    NSString* existingSectionID =
        (NSString*)logSection[@"appID"] ?: @"empty_app_id";
    NSDate* existingTimestamp = (NSDate*)logSection[@"timestamp"];
    NSString* existingBulletinID =
        (NSString*)logSection[@"bulletinID"] ?: @"empty_bulletin_id";
    if (existingTimestamp && [existingTimestamp isKindOfClass:NSDate.class] &&
        [existingTimestamp respondsToSelector:@selector(isEqualToDate:)] &&
        [existingTimestamp isEqualToDate:bulletin.date] &&
        XEq(existingBulletinID, currBulletinID) &&
        XEq(existingSectionID, currSectionID)) {
      existingLogSection = [logSection mutableCopy];
      replaceIdx = i;
      break;
    }
  }

  if (!existingLogSection || replaceIdx == -1) {
    existingLogSection = [@{
      @"appID" : currSectionID,
      @"bulletinID" : currBulletinID,
      @"timestamp" : bulletin.date
    } mutableCopy];
    [logSections addObject:existingLogSection];
  }

  NSMutableArray* logs = [(existingLogSection[@"logs"] ?: @[]) mutableCopy];
  existingLogSection[@"logs"] = logs;

  if (logs.count == 0) {
    [logs addObject:XStr(@"Processing %@", bulletin.sectionID)];
  }

  NSString* logItem = nil;
  // if only one passed, only do one of them
  if ((label && !object) || (!label && object)) {
    logItem =
        label ?: [NSPushLog stringForObject:object dontTruncate:dontTruncate];
  } else {
    logItem = XStr(@"%@: %@", label,
                   [NSPushLog stringForObject:object
                                 dontTruncate:dontTruncate]);
  }
  [logs addObject:logItem];

  if (replaceIdx > -1) {
    [logSections replaceObjectAtIndex:replaceIdx withObject:existingLogSection];
  }

  // only keep last 100
  if (logSections.count > 100) {
    NSRange rangeToDelete = NSMakeRange(0, logSections.count - 100);
    [logSections removeObjectsInRange:rangeToDelete];
  }

  CFPreferencesSetValue((__bridge CFStringRef)logKey,
                        (__bridge CFPropertyListRef)logSections, PUSHER_LOG_ID,
                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  CFPreferencesSynchronize(PUSHER_LOG_ID, kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);
  notify_post(PUSHER_LOG_PREFS_NOTIFICATION);
}

+ (void)addToLogIfEnabledForService:(NSString*)service
                           bulletin:(BBBulletin*)bulletin
                              label:(NSString*)label
                             object:(id)object {
  [NSPushLog addToLogIfEnabledForService:service
                                bulletin:bulletin
                                   label:label
                                  object:object
                            dontTruncate:NO];
}

@end
