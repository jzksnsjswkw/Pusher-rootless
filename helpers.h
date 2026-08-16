#import <Foundation/Foundation.h>

// PUSHER_SEGMENT_CELL_DEFAULT (used by NSPushIntegerValueResolved below) lives
// in the Core constants header; pulling it in here is harmless (it is
// dependency-free) and keeps the resolved accessor usable everywhere.
#import "Core/NSPushConstants.h"

NS_INLINE BOOL NSPushBoolValue(id value) {
  if ([value isKindOfClass:NSNumber.class] ||
      [value isKindOfClass:NSString.class]) {
    return [value boolValue];
  }
  return NO;
}

NS_INLINE BOOL NSPushBoolResolved(id value, BOOL defaultValue) {
  if ([value isKindOfClass:NSNumber.class] ||
      [value isKindOfClass:NSString.class]) {
    return [value boolValue];
  }
  return defaultValue;
}

NS_INLINE NSInteger NSPushIntegerValue(id value, NSInteger defaultValue) {
  if ([value isKindOfClass:NSNumber.class]) {
    return [value integerValue];
  }
  if ([value isKindOfClass:NSString.class]) {
    return [(NSString*)value integerValue];
  }
  return defaultValue;
}

// Strict integer accessor: only a complete integer literal is accepted
// (NSNumber, or an NSString that trims to a wholly numeric string like "12").
// Partial or non-numeric strings ("abc", "12x") fall back to defaultValue
// instead of silently parsing to 0.
NS_INLINE NSInteger NSPushIntegerValueStrict(id value, NSInteger defaultValue) {
  if ([value isKindOfClass:NSNumber.class]) {
    return [value integerValue];
  }
  if ([value isKindOfClass:NSString.class]) {
    NSString* stringValue = [(NSString*)value
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (stringValue.length == 0) {
      return defaultValue;
    }
    NSScanner* scanner = [NSScanner scannerWithString:stringValue];
    NSInteger result = 0;
    if ([scanner scanInteger:&result] && [scanner isAtEnd]) {
      return result;
    }
  }
  return defaultValue;
}

NS_INLINE NSString* NSPushStringValue(id value, NSString* defaultValue) {
  return [value isKindOfClass:NSString.class] ? (NSString*)value
                                              : defaultValue;
}

// Resolved integer accessor: strict parse result, treating both invalid values
// (NSIntegerMin sentinel) and the "-1 means default" segment-cell sentinel as
// "use defaultValue".
NS_INLINE NSInteger NSPushIntegerValueResolved(id value,
                                               NSInteger defaultValue) {
  NSInteger v = NSPushIntegerValueStrict(value, NSIntegerMin);
  return (v == NSIntegerMin || v == PUSHER_SEGMENT_CELL_DEFAULT)
             ? defaultValue
             : v;
}

NS_INLINE NSDictionary* NSPushDictionaryValue(id value) {
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

NS_INLINE NSArray* NSPushArrayValue(id value) {
  return [value isKindOfClass:NSArray.class] ? value : nil;
}

#define XStr(...) [NSString stringWithFormat:__VA_ARGS__]
#define XLog(...)                                                              \
  NSLog(@"[%@:%@:%d] %@", kName, [NSString stringWithUTF8String:__FILE__],     \
        __LINE__, XStr(__VA_ARGS__))
#define XEq(a, b) (a != nil && b != nil && [a isEqualToString:b])
#define XIsEmpty(a) (a == nil || [a length] == 0)
#define XAlertBtnHandler(title, h)                                             \
  [UIAlertAction actionWithTitle:title                                         \
                           style:UIAlertActionStyleDefault                     \
                         handler:h]
#define XAlertBtn(title) XAlertBtnHandler(title, nil)
#define XAlertTitle(title, msg)                                                \
  [UIAlertController alertControllerWithTitle:title                            \
                                      message:msg                              \
                               preferredStyle:UIAlertControllerStyleAlert]
#define XAlert(msg) XAlertTitle(kName, msg)
#define XUrl(url)                                                              \
  [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url]         \
                                     options:@{}                               \
                           completionHandler:nil]
#define XStrDefault(val, def)                                                  \
  (val == nil || ![val isKindOfClass:NSString.class] ||                        \
           ((NSString*)val).length == 0                                        \
       ? def                                                                   \
       : val)
