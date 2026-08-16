#import "NSPSharedSpecifiers.h"
#import "NSPLocalization.h"
#import "NSPSharedSpecifiers+ServiceBuilders.h"
#import "../Generated/BuiltinServices.generated.h"
#import "../Shared/NSPushPrefsStore.h"
#import "../global.h"
#import "../helpers.h"

@implementation NSPSharedSpecifiers

// Thin re-exports of the shared preference store, kept for callers outside
// this file (see NSPSharedSpecifiers.h). All nested built-in / custom /
// global navigation below goes through NSPushPrefsStore directly.

+ (id)getPreference:(CFStringRef)keyRef {
  return [NSPushPrefsStore preferenceValueForKey:(__bridge NSString*)keyRef];
}

+ (void)setPreference:(CFStringRef)keyRef
                value:(CFPropertyListRef)val
         shouldNotify:(BOOL)shouldNotify {
  [NSPushPrefsStore setPreferenceValue:(__bridge id)val
                                forKey:(__bridge NSString*)keyRef
                          shouldNotify:shouldNotify];
}

+ (NSArray*)get:(NSString*)service
          withAppID:(NSString*)appID
    isCustomService:(BOOL)isCustomService {
  if (isCustomService) {
    return [NSPSharedSpecifiers getCustomShared:service withAppID:appID];
  }
  if (XEq(service, PUSHER_SERVICE_PUSHOVER)) {
    return [NSPSharedSpecifiers pushover:appID];
  } else if (XEq(service, PUSHER_SERVICE_PUSHBULLET)) {
    return [NSPSharedSpecifiers pushbullet:appID];
  } else if (XEq(service, PUSHER_SERVICE_IFTTT)) {
    return [NSPSharedSpecifiers ifttt:appID];
  } else if (XEq(service, PUSHER_SERVICE_PUSHER_RECEIVER)) {
    return [NSPSharedSpecifiers pusherReceiver:appID];
  } else if (XEq(service, PUSHER_SERVICE_WECHAT)) {
    return [NSPSharedSpecifiers wechat:appID];
  }
  return @[];
}

// get for main service prefs, not custom app
+ (NSArray*)get:(NSString*)service {
  return [NSPSharedSpecifiers get:service withAppID:nil isCustomService:NO];
}

+ (NSArray*)getCustom:(NSString*)service ref:(PSListController*)listController {
  NSArray* specifiers =
      [listController loadSpecifiersFromPlistName:@"Custom"
                                           target:listController];

  NSArray* specialCells = @[ @(PSGroupCell), @(PSButtonCell), @(PSLinkCell) ];

  for (PSSpecifier* specifier in specifiers) {
    [specifier setProperty:service forKey:@"service"];
    if ([specialCells
            containsObject:@(specifier
                                 .cellType)]) { // don't set these properties on
                                                // group specifiers
      if (XEq(specifier.name, @"App List") ||
        XEq(specifier.name, NSPLocalizedString(@"App List", nil))) {
        // Custom service app lists live nested inside the service object
        // (CustomServices[service][appList]), like built-in services. The app
        // list controller needs to know which storage to use.
        [specifier setProperty:@YES forKey:@"isCustomService"];
      } else if (XEq(specifier.name, @"App Customization") ||
                 XEq(specifier.name, NSPLocalizedString(@"App Customization", nil))) {
        [specifier setProperty:service forKey:@"service"];
      }
      continue;
    }
    [specifier setProperty:@YES forKey:@"enabled"];
    [specifier setProperty:@NO forKey:@"isCustomApp"];
    specifier->setter = @selector(setPreferenceValue:forCustomSpecifier:);
    specifier->getter = @selector(readCustomPreferenceValue:);
    specifier.target = self;
  }

  return specifiers;
}

+ (void)setPreferenceValue:(id)value
    forBuiltInServiceSpecifier:(PSSpecifier*)specifier {
  NSString* service = [specifier propertyForKey:@"service"];
  BOOL isCustomApp =
      NSPushBoolResolved([specifier propertyForKey:@"isCustomApp"], NO);

  if (isCustomApp) {
    NSMutableDictionary* customApp = [[NSPushPrefsStore
        customAppPrefsForService:service
                    customAppID:[specifier propertyForKey:@"customAppID"]
                isCustomService:NO] mutableCopy];
    customApp[[specifier propertyForKey:@"customAppsPrefsKey"]] = value;
    [NSPushPrefsStore setCustomAppPrefs:customApp
                             forService:service
                           customAppID:[specifier propertyForKey:@"customAppID"]
                       isCustomService:NO
                          shouldNotify:YES];
    return;
  }

  NSMutableDictionary* serviceObj =
      [[NSPushPrefsStore serviceForName:service isCustomService:NO] mutableCopy];
  NSString* key = [specifier propertyForKey:@"key"];
  // appListIsBlacklist defaults to YES, so a YES value is the default and is
  // not stored (removing the entry keeps prefs clean; reads fall back to the
  // default). Only non-default values are persisted.
  if (value &&
      !(XEq(key, NSPPreferenceServiceAppListIsBlacklistKey) &&
        NSPushBoolValue(value))) {
    serviceObj[key] = value;
  } else {
    [serviceObj removeObjectForKey:key];
  }
  [NSPushPrefsStore setService:serviceObj
                       forName:service
               isCustomService:NO
                  shouldNotify:YES];
}

+ (id)readBuiltInServicePreferenceValue:(PSSpecifier*)specifier {
  NSString* service = [specifier propertyForKey:@"service"];
  BOOL isCustomApp =
      NSPushBoolResolved([specifier propertyForKey:@"isCustomApp"], NO);
  if (isCustomApp) {
    return [[NSPushPrefsStore customAppPrefsForService:service
                                          customAppID:[specifier propertyForKey:@"customAppID"]
                                      isCustomService:NO]
        objectForKey:[specifier propertyForKey:@"customAppsPrefsKey"]];
  }
  id value =
      [[NSPushPrefsStore serviceForName:service isCustomService:NO]
          objectForKey:[specifier propertyForKey:@"key"]];
  NSString* globalKey = [specifier propertyForKey:@"globalKey"];
  if (!value && globalKey) {
    value = [NSPushPrefsStore preferenceValueForKey:globalKey];
  }
  return value ?: [specifier propertyForKey:@"default"];
}

+ (NSArray*)builtInServiceAppListForService:(NSString*)service {
  return NSPushArrayValue(
      [[NSPushPrefsStore serviceForName:service isCustomService:NO]
          objectForKey:NSPPreferenceServiceAppListKey]) ?: @[];
}

+ (void)setBuiltInServiceAppList:(NSArray*)appList
                      forService:(NSString*)service {
  NSMutableDictionary* serviceObj =
      [[NSPushPrefsStore serviceForName:service isCustomService:NO] mutableCopy];
  serviceObj[NSPPreferenceServiceAppListKey] = appList;
  [NSPushPrefsStore setService:serviceObj
                       forName:service
               isCustomService:NO
                  shouldNotify:YES];
}

+ (NSArray*)customServiceAppListForService:(NSString*)service {
  return NSPushArrayValue(
      [[NSPushPrefsStore serviceForName:service isCustomService:YES]
          objectForKey:NSPPreferenceServiceAppListKey]) ?: @[];
}

+ (void)setCustomServiceAppList:(NSArray*)appList
                     forService:(NSString*)service {
  NSMutableDictionary* serviceObj =
      [[NSPushPrefsStore serviceForName:service isCustomService:YES] mutableCopy];
  serviceObj[NSPPreferenceServiceAppListKey] = appList;
  [NSPushPrefsStore setService:serviceObj
                       forName:service
               isCustomService:YES
                  shouldNotify:YES];
}

+ (NSArray*)globalAppList {
  NSDictionary* global = [NSPushPrefsStore global];
  return NSPushArrayValue(global[NSPPreferenceServiceAppListKey]) ?: @[];
}

+ (void)setGlobalAppList:(NSArray*)appList {
  NSMutableDictionary* global = [[NSPushPrefsStore global] mutableCopy];
  global[NSPPreferenceServiceAppListKey] = appList;
  [NSPushPrefsStore setPreferenceValue:global
                                forKey:NSPPreferenceGlobalKey
                          shouldNotify:YES];
}

+ (void)setPreferenceValue:(id)value forGlobalSpecifier:(PSSpecifier*)specifier {
  NSMutableDictionary* global = [[NSPushPrefsStore global] mutableCopy];
  NSString* key = [specifier propertyForKey:@"key"];
  // appListIsBlacklist defaults to YES; YES is the default so it is not
  // stored (see setPreferenceValue:forBuiltInServiceSpecifier:).
  if (value &&
      !(XEq(key, NSPPreferenceServiceAppListIsBlacklistKey) &&
        NSPushBoolValue(value))) {
    global[key] = value;
  } else {
    [global removeObjectForKey:key];
  }
  [NSPushPrefsStore setPreferenceValue:global
                                forKey:NSPPreferenceGlobalKey
                          shouldNotify:YES];
}

+ (id)readGlobalPreferenceValue:(PSSpecifier*)specifier {
  id value =
      [[NSPushPrefsStore global] objectForKey:[specifier propertyForKey:@"key"]];
  return value ?: [specifier propertyForKey:@"default"];
}

+ (void)setPreferenceValue:(id)value
        forCustomSpecifier:(PSSpecifier*)specifier {
  BOOL isCustomApp =
      NSPushBoolResolved([specifier propertyForKey:@"isCustomApp"], NO);
  NSString* service = [specifier propertyForKey:@"service"];

  if (isCustomApp) {
    NSMutableDictionary* customApp = [[NSPushPrefsStore
        customAppPrefsForService:service
                    customAppID:[specifier propertyForKey:@"customAppID"]
                isCustomService:YES] mutableCopy];
    customApp[[specifier propertyForKey:@"key"]] = value;
    [NSPushPrefsStore setCustomAppPrefs:customApp
                             forService:service
                           customAppID:[specifier propertyForKey:@"customAppID"]
                       isCustomService:YES
                          shouldNotify:YES];
    return;
  }

  NSMutableDictionary* customService =
      [[NSPushPrefsStore serviceForName:service isCustomService:YES] mutableCopy];
  NSString* key = [specifier propertyForKey:@"key"];
  // appListIsBlacklist defaults to YES; YES is the default so it is not
  // stored (see setPreferenceValue:forBuiltInServiceSpecifier:).
  if (value &&
      !(XEq(key, NSPPreferenceServiceAppListIsBlacklistKey) &&
        NSPushBoolValue(value))) {
    customService[key] = value;
  } else {
    [customService removeObjectForKey:key];
  }
  [NSPushPrefsStore setService:customService
                       forName:service
               isCustomService:YES
                  shouldNotify:YES];
}

+ (id)readCustomPreferenceValue:(PSSpecifier*)specifier {
  BOOL isCustomApp =
      NSPushBoolResolved([specifier propertyForKey:@"isCustomApp"], NO);
  NSString* service = [specifier propertyForKey:@"service"];
  if (isCustomApp) {
    return [[NSPushPrefsStore customAppPrefsForService:service
                                          customAppID:[specifier propertyForKey:@"customAppID"]
                                      isCustomService:YES]
        objectForKey:[specifier propertyForKey:@"key"]];
  }
  id value = [[NSPushPrefsStore serviceForName:service isCustomService:YES]
      objectForKey:[specifier propertyForKey:@"key"]];
  NSString* globalKey = [specifier propertyForKey:@"globalKey"];
  if (!value && globalKey) {
    value = [NSPushPrefsStore preferenceValueForKey:globalKey];
  }
  return value ?: [specifier propertyForKey:@"default"];
}

@end
