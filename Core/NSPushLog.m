#import "NSPushLog.h"
#import "NSPushConstants.h"
#import "../Shared/NSPushLogStore.h"
#import "helpers.h"

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
  if (![service isKindOfClass:NSString.class]) {
    service = @"";
  }
  // allow global service which is @"" so empty
  if (!XIsEmpty(service)) {
    id val = CFBridgingRelease(CFPreferencesCopyAppValue(
        (__bridge CFStringRef)XStr(@"%@LogEnabled", service), PUSHER_APP_ID));
    // Guard the type: prefs can hold a non-NSNumber value, and messaging
    // boolValue on it would crash. NSString also implements boolValue.
    BOOL logEnabled = YES;
    if ([val isKindOfClass:NSNumber.class] ||
        [val isKindOfClass:NSString.class]) {
      logEnabled = [val boolValue];
    }
    if (!logEnabled) {
      XLog(@"[S:%@] Log Disabled", service);
      return;
    }
  }

  NSDictionary* prefs = [NSPushLogStore snapshot];

  NSString* logKey = XStr(@"%@Log", service);
  // Guard against malformed log prefs: the value must be an array before we
  // treat it as a list of log sections.
  id rawLogSections = prefs[logKey];
  NSMutableArray* logSections =
      [rawLogSections isKindOfClass:NSArray.class]
          ? [(NSArray*)rawLogSections mutableCopy]
          : [NSMutableArray new];

  NSString* currBulletinID = bulletin.bulletinID ?: @"empty_bulletin_id";
  NSString* currSectionID = bulletin.sectionID ?: @"empty_app_id";
  NSMutableDictionary* existingLogSection = nil;
  int replaceIdx = -1;
  for (int i = 0; i < logSections.count; i++) {
    id rawLogSection = logSections[i];
    if (![rawLogSection isKindOfClass:NSDictionary.class]) {
      continue;
    }
    NSDictionary* logSection = (NSDictionary*)rawLogSection;
    NSString* existingSectionID = @"empty_app_id";
    if ([logSection[@"appID"] isKindOfClass:NSString.class]) {
      existingSectionID = (NSString*)logSection[@"appID"];
    }
    NSDate* existingTimestamp = nil;
    if ([logSection[@"timestamp"] isKindOfClass:NSDate.class]) {
      existingTimestamp = (NSDate*)logSection[@"timestamp"];
    }
    NSString* existingBulletinID = @"empty_bulletin_id";
    if ([logSection[@"bulletinID"] isKindOfClass:NSString.class]) {
      existingBulletinID = (NSString*)logSection[@"bulletinID"];
    }
    if (existingTimestamp &&
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

  id rawLogs = existingLogSection[@"logs"];
  NSMutableArray* logs =
      [rawLogs isKindOfClass:NSArray.class]
          ? [(NSArray*)rawLogs mutableCopy]
          : [NSMutableArray new];
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

  [NSPushLogStore setLogSections:logSections
                     forService:service
                   shouldNotify:YES];
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
