#import "NSPushPrefsStore.h"
#import "../Core/NSPushConstants.h"
#import "../helpers.h"
#import <notify.h>

@implementation NSPushPrefsStore

+ (id)preferenceValueForKey:(NSString*)key {
  if (![key isKindOfClass:NSString.class] || key.length == 0) {
    return nil;
  }
  CFPropertyListRef val = CFPreferencesCopyValue(
      (__bridge CFStringRef)key, PUSHER_APP_ID, kCFPreferencesCurrentUser,
      kCFPreferencesAnyHost);
  return val ? (__bridge_transfer id)val : nil;
}

+ (void)setPreferenceValue:(id)value
                    forKey:(NSString*)key
              shouldNotify:(BOOL)shouldNotify {
  if (![key isKindOfClass:NSString.class] || key.length == 0) {
    return;
  }
  CFPreferencesSetValue((__bridge CFStringRef)key,
                        (__bridge CFPropertyListRef)value, PUSHER_APP_ID,
                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);
  if (shouldNotify) {
    notify_post(PUSHER_PREFS_NOTIFICATION);
  }
}

+ (NSDictionary*)snapshot {
  CFArrayRef keyList = CFPreferencesCopyKeyList(
      PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  NSDictionary* prefs = @{};
  if (keyList) {
    prefs = CFBridgingRelease(CFPreferencesCopyMultiple(
        keyList, PUSHER_APP_ID, kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost));
    if (!prefs) {
      prefs = @{};
    }
    CFRelease(keyList);
  }
  return prefs;
}

+ (void)applySnapshot:(NSDictionary*)prefs
           removeKeys:(NSArray*)keys
         shouldNotify:(BOOL)shouldNotify {
  CFPreferencesSetMultiple((__bridge CFDictionaryRef)prefs,
                           (__bridge CFArrayRef)(keys ?: @[]), PUSHER_APP_ID,
                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);
  if (shouldNotify) {
    notify_post(PUSHER_PREFS_NOTIFICATION);
  }
}

+ (NSDictionary*)builtInServices {
  return NSPushDictionaryValue(
             [self preferenceValueForKey:NSPPreferenceBuiltInServicesKey])
      ?: @{};
}

+ (NSDictionary*)customServices {
  return NSPushDictionaryValue(
             [self preferenceValueForKey:NSPPreferenceCustomServicesKey])
      ?: @{};
}

+ (NSDictionary*)global {
  return NSPushDictionaryValue(
             [self preferenceValueForKey:NSPPreferenceGlobalKey])
      ?: @{};
}

+ (NSDictionary*)serviceForName:(NSString*)name
                isCustomService:(BOOL)isCustom {
  if (![name isKindOfClass:NSString.class] || name.length == 0) {
    return @{};
  }
  NSDictionary* container =
      isCustom ? [self customServices] : [self builtInServices];
  return NSPushDictionaryValue(container[name]) ?: @{};
}

+ (void)setService:(NSDictionary*)serviceObj
           forName:(NSString*)name
   isCustomService:(BOOL)isCustom
      shouldNotify:(BOOL)shouldNotify {
  if (![name isKindOfClass:NSString.class] || name.length == 0) {
    return;
  }
  NSMutableDictionary* container = [NSMutableDictionary new];
  [container addEntriesFromDictionary:isCustom ? [self customServices]
                                               : [self builtInServices]];
  if (serviceObj) {
    container[name] = serviceObj;
  } else {
    [container removeObjectForKey:name];
  }
  [self setPreferenceValue:container
                    forKey:isCustom ? NSPPreferenceCustomServicesKey
                                    : NSPPreferenceBuiltInServicesKey
              shouldNotify:shouldNotify];
}

+ (NSDictionary*)customAppPrefsForService:(NSString*)name
                             customAppID:(NSString*)customAppID
                         isCustomService:(BOOL)isCustom {
  if (![customAppID isKindOfClass:NSString.class] || customAppID.length == 0) {
    return @{};
  }
  NSDictionary* serviceObj = [self serviceForName:name
                                  isCustomService:isCustom];
  NSDictionary* customApps =
      NSPushDictionaryValue(serviceObj[NSPPreferenceServiceCustomAppsKey])
      ?: @{};
  return NSPushDictionaryValue(customApps[customAppID]) ?: @{};
}

+ (void)setCustomAppPrefs:(NSDictionary*)appPrefs
                forService:(NSString*)name
              customAppID:(NSString*)customAppID
          isCustomService:(BOOL)isCustom
             shouldNotify:(BOOL)shouldNotify {
  if (![customAppID isKindOfClass:NSString.class] || customAppID.length == 0) {
    return;
  }
  NSMutableDictionary* serviceObj =
      [[self serviceForName:name isCustomService:isCustom] mutableCopy];
  NSMutableDictionary* customApps =
      [(NSPushDictionaryValue(serviceObj[NSPPreferenceServiceCustomAppsKey])
              ?: @{}) mutableCopy];
  if (appPrefs) {
    customApps[customAppID] = appPrefs;
  } else {
    [customApps removeObjectForKey:customAppID];
  }
  serviceObj[NSPPreferenceServiceCustomAppsKey] = customApps;
  [self setService:serviceObj
           forName:name
   isCustomService:isCustom
      shouldNotify:shouldNotify];
}

@end