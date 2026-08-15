#import <Foundation/Foundation.h>

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
