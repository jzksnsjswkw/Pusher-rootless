#import "NSPSharedSpecifiers.h"
#import "NSPDeviceSoundListController.h"

#import "../global.h"
#import "../helpers.h"
#import <notify.h>

@implementation NSPSharedSpecifiers

+ (id)getPreference:(CFStringRef)keyRef {
  CFPropertyListRef val = CFPreferencesCopyValue(
      keyRef, PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  return val ? (__bridge_transfer id)val : nil;
}

+ (void)setPreference:(CFStringRef)keyRef
                value:(CFPropertyListRef)val
         shouldNotify:(BOOL)shouldNotify {
  CFPreferencesSetValue(keyRef, val, PUSHER_APP_ID, kCFPreferencesCurrentUser,
                        kCFPreferencesAnyHost);
  CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser,
                           kCFPreferencesAnyHost);
  if (shouldNotify) {
    // Reload stuff
    notify_post(PUSHER_PREFS_NOTIFICATION);
  }
}

+ (int)countAppIDsWithPrefix:(NSDictionary*)prefs prefix:(NSString*)prefix {
  int count = 0;
  for (id key in prefs.allKeys) {
    if (![key isKindOfClass:NSString.class]) {
      continue;
    }
    if ([key hasPrefix:prefix] && ((NSNumber*)prefs[key]).boolValue) {
      count += 1;
    }
  }
  return count;
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
      if (XEq(specifier.name, @"App List")) {
        [specifier setProperty:NSPPreferenceCustomServiceBLPrefix(service)
                        forKey:@"ALSettingsKeyPrefix"];
      } else if (XEq(specifier.name, @"App Customization")) {
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

+ (NSArray*)getCustomShared:(NSString*)service withAppID:(NSString*)appID {
  BOOL isCustomApp = appID != nil;

  PSSpecifier* includeIcon = [PSSpecifier
      preferenceSpecifierNamed:@"Include Icon"
                        target:self
                           set:@selector(setPreferenceValue:forCustomSpecifier:)
                           get:@selector(readCustomPreferenceValue:)
                        detail:nil
                          cell:PSSwitchCell
                          edit:nil];
  [includeIcon setProperty:@"includeIcon" forKey:@"key"];
  [includeIcon setProperty:@YES forKey:@"enabled"];
  [includeIcon setProperty:@NO forKey:@"default"];
  [includeIcon setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [includeIcon setProperty:service forKey:@"service"];

  PSSpecifier* includeImage = [PSSpecifier
      preferenceSpecifierNamed:@"Include Image"
                        target:self
                           set:@selector(setPreferenceValue:forCustomSpecifier:)
                           get:@selector(readCustomPreferenceValue:)
                        detail:nil
                          cell:PSSwitchCell
                          edit:nil];
  [includeImage setProperty:@"includeImage" forKey:@"key"];
  [includeImage setProperty:@YES forKey:@"enabled"];
  [includeImage setProperty:@NO forKey:@"default"];
  [includeImage setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [includeImage setProperty:service forKey:@"service"];

  PSSpecifier* imageMaxWidth = [PSSpecifier
      preferenceSpecifierNamed:@"Maximum Image Width (pixels)"
                        target:self
                           set:@selector(setPreferenceValue:forCustomSpecifier:)
                           get:@selector(readCustomPreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [imageMaxWidth setProperty:@"imageMaxWidth" forKey:@"key"];
  [imageMaxWidth setProperty:@YES forKey:@"enabled"];
  [imageMaxWidth setProperty:@YES forKey:@"isDecimalPad"];
  [imageMaxWidth setProperty:@(PUSHER_DEFAULT_MAX_WIDTH) forKey:@"default"];
  [imageMaxWidth setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [imageMaxWidth setProperty:service forKey:@"service"];

  PSSpecifier* imageMaxHeight = [PSSpecifier
      preferenceSpecifierNamed:@"Maximum Image Height (pixels)"
                        target:self
                           set:@selector(setPreferenceValue:forCustomSpecifier:)
                           get:@selector(readCustomPreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [imageMaxHeight setProperty:@"imageMaxHeight" forKey:@"key"];
  [imageMaxHeight setProperty:@YES forKey:@"enabled"];
  [imageMaxHeight setProperty:@YES forKey:@"isDecimalPad"];
  [imageMaxHeight setProperty:@(PUSHER_DEFAULT_MAX_HEIGHT) forKey:@"default"];
  [imageMaxHeight setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [imageMaxHeight setProperty:service forKey:@"service"];

  PSSpecifier* imageShrinkFactor = [PSSpecifier
      preferenceSpecifierNamed:@"Image Shrink Factor Upon Retry"
                        target:self
                           set:@selector(setPreferenceValue:forCustomSpecifier:)
                           get:@selector(readCustomPreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [imageShrinkFactor setProperty:@"imageShrinkFactor" forKey:@"key"];
  [imageShrinkFactor setProperty:@YES forKey:@"enabled"];
  [imageShrinkFactor setProperty:@YES forKey:@"isDecimalPad"];
  [imageShrinkFactor setProperty:@(PUSHER_DEFAULT_SHRINK_FACTOR)
                          forKey:@"default"];
  [imageShrinkFactor setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [imageShrinkFactor setProperty:service forKey:@"service"];

  if (isCustomApp) {
    [includeIcon setProperty:appID forKey:@"customAppID"];
    [includeImage setProperty:appID forKey:@"customAppID"];
    [imageMaxWidth setProperty:appID forKey:@"customAppID"];
    [imageMaxHeight setProperty:appID forKey:@"customAppID"];
    [imageShrinkFactor setProperty:appID forKey:@"customAppID"];
  }

  return @[
    includeIcon, includeImage, imageMaxWidth, imageMaxHeight, imageShrinkFactor
  ];
}

+ (NSArray*)getCustomShared:(NSString*)service {
  return [NSPSharedSpecifiers getCustomShared:service withAppID:nil];
}

+ (NSArray*)pushover:(NSString*)appID {
  PSSpecifier* devices =
      [PSSpecifier preferenceSpecifierNamed:@"Receiving Devices"
                                     target:nil
                                        set:nil
                                        get:nil
                                     detail:NSPDeviceSoundListController.class
                                       cell:PSLinkCell
                                       edit:nil];
  PSSpecifier* sounds =
      [PSSpecifier preferenceSpecifierNamed:@"Notification Sound"
                                     target:nil
                                        set:nil
                                        get:nil
                                     detail:NSPDeviceSoundListController.class
                                       cell:PSLinkCell
                                       edit:nil];

  [devices setProperty:PUSHER_SERVICE_PUSHOVER forKey:@"service"];
  [sounds setProperty:PUSHER_SERVICE_PUSHOVER forKey:@"service"];

  BOOL isCustomApp = appID != nil;

  [devices setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [sounds setProperty:@(isCustomApp) forKey:@"isCustomApp"];

  [devices setProperty:@NO forKey:@"isSound"];
  [sounds setProperty:@YES forKey:@"isSound"];

  if (isCustomApp) {
    [devices setProperty:appID forKey:@"customAppIDKey"];
    [sounds setProperty:appID forKey:@"customAppIDKey"];
  }

  return @[ devices, sounds ];
}

+ (NSArray*)pushbullet:(NSString*)appID {
  PSSpecifier* devices =
      [PSSpecifier preferenceSpecifierNamed:@"Receiving Devices"
                                     target:nil
                                        set:nil
                                        get:nil
                                     detail:NSPDeviceSoundListController.class
                                       cell:PSLinkCell
                                       edit:nil];
  [devices setProperty:PUSHER_SERVICE_PUSHBULLET forKey:@"service"];
  BOOL isCustomApp = appID != nil;
  [devices setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [devices setProperty:@NO forKey:@"isSound"];
  if (isCustomApp) {
    [devices setProperty:appID forKey:@"customAppIDKey"];
  }
  return @[ devices ];
}

+ (NSArray*)ifttt:(NSString*)appID {
  BOOL isCustomApp = appID != nil;

  PSSpecifier* eventName = [PSSpecifier
      preferenceSpecifierNamed:@"Event Name"
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [eventName setProperty:NSPPreferenceServiceEventNameKey forKey:@"key"];
  [eventName setProperty:@YES forKey:@"enabled"];
  [eventName setProperty:@YES forKey:@"noAutoCorrect"];
  [eventName setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [eventName setProperty:PUSHER_SERVICE_IFTTT forKey:@"service"];
  [eventName setProperty:@"eventName" forKey:@"customAppsPrefsKey"];

  PSSpecifier* includeIcon = [PSSpecifier
      preferenceSpecifierNamed:@"Include Icon"
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSSwitchCell
                          edit:nil];
  [includeIcon setProperty:NSPPreferenceServiceIncludeIconKey forKey:@"key"];
  [includeIcon setProperty:@YES forKey:@"enabled"];
  [includeIcon setProperty:@NO forKey:@"default"];
  [includeIcon setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [includeIcon setProperty:PUSHER_SERVICE_IFTTT forKey:@"service"];
  [includeIcon setProperty:@"includeIcon" forKey:@"customAppsPrefsKey"];

  PSSpecifier* curateData = [PSSpecifier
      preferenceSpecifierNamed:@"Curate Request Data"
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSSwitchCell
                          edit:nil];
  [curateData setProperty:NSPPreferenceServiceCurateDataKey forKey:@"key"];
  [curateData setProperty:@YES forKey:@"enabled"];
  [curateData setProperty:@YES forKey:@"default"];
  [curateData setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [curateData setProperty:PUSHER_SERVICE_IFTTT forKey:@"service"];
  [curateData setProperty:@"curateData" forKey:@"customAppsPrefsKey"];

  if (isCustomApp) {
    [eventName setProperty:appID forKey:@"customAppID"];
    [includeIcon setProperty:appID forKey:@"customAppID"];
    [curateData setProperty:appID forKey:@"customAppID"];
  }

  return @[ eventName, includeIcon, curateData ];
}

+ (NSArray*)wechat:(NSString*)appID {
  BOOL isCustomApp = appID != nil;

  PSSpecifier* touser = [PSSpecifier
      preferenceSpecifierNamed:@"Touser"
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [touser setProperty:NSPPreferenceServiceTouserKey forKey:@"key"];
  [touser setProperty:@YES forKey:@"enabled"];
  [touser setProperty:@YES forKey:@"noAutoCorrect"];
  [touser setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [touser setProperty:PUSHER_SERVICE_WECHAT forKey:@"service"];
  [touser setProperty:@"touser" forKey:@"customAppsPrefsKey"];

  if (isCustomApp) {
    [touser setProperty:appID forKey:@"customAppID"];
  }

  return @[ touser ];
}

+ (NSArray*)pusherReceiver:(NSString*)appID {
  BOOL isCustomApp = appID != nil;

  PSSpecifier* includeIcon = [PSSpecifier
      preferenceSpecifierNamed:@"Include Icon"
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSSwitchCell
                          edit:nil];
  [includeIcon setProperty:NSPPreferenceServiceIncludeIconKey forKey:@"key"];
  [includeIcon setProperty:@YES forKey:@"enabled"];
  [includeIcon setProperty:@YES forKey:@"default"];
  [includeIcon setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [includeIcon setProperty:PUSHER_SERVICE_PUSHER_RECEIVER forKey:@"service"];
  [includeIcon setProperty:@"includeIcon" forKey:@"customAppsPrefsKey"];

  PSSpecifier* includeImage = [PSSpecifier
      preferenceSpecifierNamed:@"Include Image"
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSSwitchCell
                          edit:nil];
  [includeImage setProperty:NSPPreferenceServiceIncludeImageKey forKey:@"key"];
  [includeImage setProperty:@YES forKey:@"enabled"];
  [includeImage setProperty:@YES forKey:@"default"];
  [includeImage setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [includeImage setProperty:PUSHER_SERVICE_PUSHER_RECEIVER forKey:@"service"];
  [includeImage setProperty:@"includeImage" forKey:@"customAppsPrefsKey"];

  PSSpecifier* imageMaxWidth = [PSSpecifier
      preferenceSpecifierNamed:@"Maximum Image Width (pixels)"
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [imageMaxWidth setProperty:NSPPreferenceServiceImageMaxWidthKey
                      forKey:@"key"];
  [imageMaxWidth setProperty:@YES forKey:@"enabled"];
  [imageMaxWidth setProperty:@YES forKey:@"isDecimalPad"];
  [imageMaxWidth setProperty:@(PUSHER_DEFAULT_MAX_WIDTH) forKey:@"default"];
  [imageMaxWidth setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [imageMaxWidth setProperty:PUSHER_SERVICE_PUSHER_RECEIVER forKey:@"service"];
  [imageMaxWidth setProperty:@"imageMaxWidth" forKey:@"customAppsPrefsKey"];

  PSSpecifier* imageMaxHeight = [PSSpecifier
      preferenceSpecifierNamed:@"Maximum Image Height (pixels)"
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [imageMaxHeight setProperty:NSPPreferenceServiceImageMaxHeightKey
                       forKey:@"key"];
  [imageMaxHeight setProperty:@YES forKey:@"enabled"];
  [imageMaxHeight setProperty:@YES forKey:@"isDecimalPad"];
  [imageMaxHeight setProperty:@(PUSHER_DEFAULT_MAX_HEIGHT) forKey:@"default"];
  [imageMaxHeight setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [imageMaxHeight setProperty:PUSHER_SERVICE_PUSHER_RECEIVER forKey:@"service"];
  [imageMaxHeight setProperty:@"imageMaxHeight" forKey:@"customAppsPrefsKey"];

  PSSpecifier* imageShrinkFactor = [PSSpecifier
      preferenceSpecifierNamed:@"Image Shrink Factor Upon Retry"
                        target:self
                           set:@selector(setPreferenceValue:
                                         forBuiltInServiceSpecifier:)
                           get:@selector(readBuiltInServicePreferenceValue:)
                        detail:nil
                          cell:PSEditTextCell
                          edit:nil];
  [imageShrinkFactor setProperty:NSPPreferenceServiceImageShrinkFactorKey
                          forKey:@"key"];
  [imageShrinkFactor setProperty:@YES forKey:@"enabled"];
  [imageShrinkFactor setProperty:@YES forKey:@"isDecimalPad"];
  [imageShrinkFactor setProperty:@(PUSHER_DEFAULT_SHRINK_FACTOR)
                          forKey:@"default"];
  [imageShrinkFactor setProperty:@(isCustomApp) forKey:@"isCustomApp"];
  [imageShrinkFactor setProperty:PUSHER_SERVICE_PUSHER_RECEIVER
                          forKey:@"service"];
  [imageShrinkFactor setProperty:@"imageShrinkFactor"
                          forKey:@"customAppsPrefsKey"];

  if (isCustomApp) {
    [includeIcon setProperty:appID forKey:@"customAppID"];
    [includeImage setProperty:appID forKey:@"customAppID"];
    [imageMaxWidth setProperty:appID forKey:@"customAppID"];
    [imageMaxHeight setProperty:appID forKey:@"customAppID"];
    [imageShrinkFactor setProperty:appID forKey:@"customAppID"];
  }

  return @[
    includeIcon, includeImage, imageMaxWidth, imageMaxHeight, imageShrinkFactor
  ];
}

+ (void)setPreferenceValue:(id)value
    forBuiltInServiceSpecifier:(PSSpecifier*)specifier {
  NSString* service = [specifier propertyForKey:@"service"];
  NSMutableDictionary* builtInServices =
      [([NSPSharedSpecifiers
            getPreference:(__bridge CFStringRef)NSPPreferenceBuiltInServicesKey]
            ?: @{}) mutableCopy];
  NSMutableDictionary* serviceObj =
      [(builtInServices[service] ?: @{}) mutableCopy];

  BOOL isCustomApp =
      [specifier propertyForKey:@"isCustomApp"] &&
      ((NSNumber*)[specifier propertyForKey:@"isCustomApp"]).boolValue;
  if (isCustomApp) {
    NSMutableDictionary* customApps =
        [(serviceObj[NSPPreferenceServiceCustomAppsKey] ?: @{}) mutableCopy];
    NSMutableDictionary* customApp =
        [(customApps[[specifier propertyForKey:@"customAppID"]]
              ?: @{}) mutableCopy];
    customApp[[specifier propertyForKey:@"customAppsPrefsKey"]] = value;
    customApps[[specifier propertyForKey:@"customAppID"]] = customApp;
    serviceObj[NSPPreferenceServiceCustomAppsKey] = customApps;
  } else {
    if (value) {
      serviceObj[[specifier propertyForKey:@"key"]] = value;
    } else {
      [serviceObj removeObjectForKey:[specifier propertyForKey:@"key"]];
    }
  }

  builtInServices[service] = serviceObj;
  [NSPSharedSpecifiers
      setPreference:(__bridge CFStringRef)NSPPreferenceBuiltInServicesKey
              value:(__bridge CFPropertyListRef)builtInServices
       shouldNotify:YES];
}

+ (id)readBuiltInServicePreferenceValue:(PSSpecifier*)specifier {
  NSString* service = [specifier propertyForKey:@"service"];
  NSDictionary* builtInServices =
      [NSPSharedSpecifiers
          getPreference:(__bridge CFStringRef)NSPPreferenceBuiltInServicesKey]
          ?: @{};
  NSDictionary* serviceObj = builtInServices[service] ?: @{};

  BOOL isCustomApp =
      [specifier propertyForKey:@"isCustomApp"] &&
      ((NSNumber*)[specifier propertyForKey:@"isCustomApp"]).boolValue;
  if (isCustomApp) {
    NSDictionary* customApps =
        serviceObj[NSPPreferenceServiceCustomAppsKey] ?: @{};
    NSDictionary* customApp =
        customApps[[specifier propertyForKey:@"customAppID"]] ?: @{};
    return customApp[[specifier propertyForKey:@"customAppsPrefsKey"]];
  }
  id value = serviceObj[[specifier propertyForKey:@"key"]];
  NSString* globalKey = [specifier propertyForKey:@"globalKey"];
  if (!value && globalKey) {
    value = [NSPSharedSpecifiers getPreference:(__bridge CFStringRef)globalKey];
  }
  return value ?: [specifier propertyForKey:@"default"];
}

+ (NSArray*)builtInServiceAppListForService:(NSString*)service {
  NSDictionary* builtInServices =
      [NSPSharedSpecifiers
          getPreference:(__bridge CFStringRef)NSPPreferenceBuiltInServicesKey]
          ?: @{};
  NSDictionary* serviceObj = builtInServices[service] ?: @{};
  return serviceObj[NSPPreferenceServiceAppListKey] ?: @[];
}

+ (void)setBuiltInServiceAppList:(NSArray*)appList
                      forService:(NSString*)service {
  NSMutableDictionary* builtInServices =
      [([NSPSharedSpecifiers
            getPreference:(__bridge CFStringRef)NSPPreferenceBuiltInServicesKey]
            ?: @{}) mutableCopy];
  NSMutableDictionary* serviceObj =
      [(builtInServices[service] ?: @{}) mutableCopy];
  serviceObj[NSPPreferenceServiceAppListKey] = appList;
  builtInServices[service] = serviceObj;
  [NSPSharedSpecifiers
      setPreference:(__bridge CFStringRef)NSPPreferenceBuiltInServicesKey
              value:(__bridge CFPropertyListRef)builtInServices
       shouldNotify:YES];
}

+ (void)setPreferenceValue:(id)value
        forCustomSpecifier:(PSSpecifier*)specifier {
  BOOL isCustomApp =
      [specifier propertyForKey:@"isCustomApp"] &&
      ((NSNumber*)[specifier propertyForKey:@"isCustomApp"]).boolValue;
  NSString* service = [specifier propertyForKey:@"service"];
  if (isCustomApp) {
    NSMutableDictionary* customApps = [((NSDictionary*)[NSPSharedSpecifiers
        getPreference:(__bridge CFStringRef)
                          NSPPreferenceCustomServiceCustomAppsKey(service)]
        ?: @{}) mutableCopy];
    NSMutableDictionary* customApp =
        [(customApps[[specifier propertyForKey:@"customAppID"]]
              ?: @{}) mutableCopy];
    customApp[[specifier propertyForKey:@"key"]] = value;
    customApps[[specifier propertyForKey:@"customAppID"]] = customApp;
    [NSPSharedSpecifiers
        setPreference:(__bridge CFStringRef)
                          NSPPreferenceCustomServiceCustomAppsKey(service)
                value:(__bridge CFPropertyListRef)customApps
         shouldNotify:YES];
  } else {
    NSMutableDictionary* customServices = [(
        [NSPSharedSpecifiers
            getPreference:(__bridge CFStringRef)NSPPreferenceCustomServicesKey]
            ?: @{}) mutableCopy];
    NSMutableDictionary* customService =
        [(customServices[service] ?: @{}) mutableCopy];
    if (value) {
      customService[[specifier propertyForKey:@"key"]] = value;
    } else {
      [customService removeObjectForKey:[specifier propertyForKey:@"key"]];
    }
    customServices[service] = customService;
    [NSPSharedSpecifiers
        setPreference:(__bridge CFStringRef)NSPPreferenceCustomServicesKey
                value:(__bridge CFPropertyListRef)customServices
         shouldNotify:YES];
  }
}

+ (id)readCustomPreferenceValue:(PSSpecifier*)specifier {
  BOOL isCustomApp =
      [specifier propertyForKey:@"isCustomApp"] &&
      ((NSNumber*)[specifier propertyForKey:@"isCustomApp"]).boolValue;
  NSString* service = [specifier propertyForKey:@"service"];
  if (isCustomApp) {
    NSDictionary* customApps =
        [NSPSharedSpecifiers
            getPreference:(__bridge CFStringRef)
                              NSPPreferenceCustomServiceCustomAppsKey(service)]
            ?: @{};
    NSDictionary* customApp =
        customApps[[specifier propertyForKey:@"customAppID"]] ?: @{};
    return customApp[[specifier propertyForKey:@"key"]];
  }
  NSDictionary* customServices =
      [NSPSharedSpecifiers
          getPreference:(__bridge CFStringRef)NSPPreferenceCustomServicesKey]
          ?: @{};
  id d = [specifier propertyForKey:@"default"];
  if (!customServices[service]) {
    return d;
  } else {
    id value = customServices[service][[specifier propertyForKey:@"key"]];
    NSString* globalKey = [specifier propertyForKey:@"globalKey"];
    if (!value && globalKey) {
      value =
          [NSPSharedSpecifiers getPreference:(__bridge CFStringRef)globalKey];
    }
    return value ?: d;
  }
}

@end
