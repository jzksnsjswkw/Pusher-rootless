#import <Foundation/Foundation.h>

// Central CFPreferences access for the Pusher preference plist
// (com.noahsaso.pusher). The tweak core (Core/NSPushConfig) and the
// Preferences bundle (NSPSharedSpecifiers and the preference controllers)
// read and write the same nested BuiltInServices / CustomServices / Global
// layout, so raw plist I/O, nested navigation and the post-write reload
// notification all live here in one dependency-free place. No UIKit /
// SpringBoard / Preferences imports. Every accessor is nil-safe.
@interface NSPushPrefsStore : NSObject

// Single top-level key.
+ (id)preferenceValueForKey:(NSString*)key;
+ (void)setPreferenceValue:(id)value
                    forKey:(NSString*)key
              shouldNotify:(BOOL)shouldNotify;

// Full raw snapshot of the plist, and bulk write-back (optionally with a list
// of keys to remove in the same cfprefsd transaction).
+ (NSDictionary*)snapshot;
+ (void)applySnapshot:(NSDictionary*)prefs
           removeKeys:(NSArray*)keys
         shouldNotify:(BOOL)shouldNotify;

// Nested top-level containers (nil-safe raw copies).
+ (NSDictionary*)builtInServices;
+ (NSDictionary*)customServices;
+ (NSDictionary*)global;

// One service's nested object, and persist it back (nil serviceObj removes
// the service from its container).
+ (NSDictionary*)serviceForName:(NSString*)name
                isCustomService:(BOOL)isCustom;
+ (void)setService:(NSDictionary*)serviceObj
           forName:(NSString*)name
   isCustomService:(BOOL)isCustom
      shouldNotify:(BOOL)shouldNotify;

// One per-app override object inside a service, and persist it back.
+ (NSDictionary*)customAppPrefsForService:(NSString*)name
                             customAppID:(NSString*)customAppID
                         isCustomService:(BOOL)isCustom;
+ (void)setCustomAppPrefs:(NSDictionary*)appPrefs
                forService:(NSString*)name
              customAppID:(NSString*)customAppID
          isCustomService:(BOOL)isCustom
             shouldNotify:(BOOL)shouldNotify;

@end