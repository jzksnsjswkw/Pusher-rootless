#import "NSPLogFormatter.h"
#import "NSPLocalization.h"
#import "../helpers.h"
#import <MobileCoreServices/LSApplicationProxy.h>

@implementation NSPLogFormatter

+ (NSString*)sectionTitleForLogSection:(NSDictionary*)logSection {
  if (![logSection isKindOfClass:NSDictionary.class]) {
    return @"";
  }

  NSString* logSectionAppID = nil;
  if ([logSection[@"appID"] isKindOfClass:NSString.class]) {
    logSectionAppID = (NSString*)logSection[@"appID"];
  }

  NSString* sectionName = nil;
  if ([logSection[@"name"] isKindOfClass:NSString.class]) {
    sectionName = (NSString*)logSection[@"name"];
  }
  if (!sectionName) {
    NSString* appName = NSPLocalizedString(@"Unknown App", nil);
    if (logSectionAppID) {
      LSApplicationProxy* appProxy =
          [LSApplicationProxy applicationProxyForIdentifier:logSectionAppID];
      appName = [appProxy localizedName] ?: appName;
    }

    NSDate* timestamp = nil;
    if ([logSection[@"timestamp"] isKindOfClass:NSDate.class]) {
      timestamp = (NSDate*)logSection[@"timestamp"];
    }
    if (timestamp) {
      NSDateFormatter* dateFormatter = [NSDateFormatter new];
      dateFormatter.dateStyle = NSDateFormatterMediumStyle;
      dateFormatter.timeStyle = NSDateFormatterMediumStyle;
      NSString* dateString = [dateFormatter stringFromDate:timestamp];
      sectionName = XStr(@"%@: %@", appName, dateString);
    } else {
      sectionName = XStr(@"%@: %@", appName, logSection[@"timestamp"]);
    }
  }

  NSString* logSectionService = nil;
  if ([logSection[@"service"] isKindOfClass:NSString.class]) {
    logSectionService = (NSString*)logSection[@"service"];
  }
  if (logSectionService) {
    if (XIsEmpty(logSectionService)) {
      sectionName = XStr(NSPLocalizedString(@"{GLOBAL} %@", nil), sectionName);
    } else {
      sectionName = XStr(NSPLocalizedString(@"[%@] %@", nil), NSPushServiceDisplayName(logSectionService), sectionName);
    }
  }

  return sectionName;
}

+ (BOOL)shouldIncludeLogs:(NSArray*)logs
          networkResponse:(NSString*)networkResponse
                endResult:(NSString*)endResult {
  if (networkResponse) {
    NSString* filterLogString = XStr(@"Network Response: %@", networkResponse);
    BOOL networkResponseFilterPasses = NO;
    for (NSString* log in logs) {
      if ([log containsString:filterLogString]) {
        networkResponseFilterPasses = YES;
        break;
      }
    }
    if (!networkResponseFilterPasses) {
      return NO;
    }
  }

  if (endResult) {
    BOOL shouldContainPushed = XEq(endResult, END_RESULT_ITEMS[2]);
    BOOL containsPushed = [logs containsObject:END_RESULT_ITEMS[2]];
    if (shouldContainPushed != containsPushed) {
      return NO;
    }
  }

  return YES;
}

@end
