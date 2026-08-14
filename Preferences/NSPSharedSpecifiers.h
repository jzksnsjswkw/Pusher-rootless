#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface NSPSharedSpecifiers : NSObject
+ (NSArray*)get:(NSString*)service
          withAppID:(NSString*)appID
    isCustomService:(BOOL)isCustomService;
+ (NSArray*)get:(NSString*)service;
+ (NSArray*)getCustom:(NSString*)service ref:(PSListController*)listController;
+ (NSArray*)getCustomShared:(NSString*)service withAppID:(NSString*)appID;
+ (NSArray*)getCustomShared:(NSString*)service;
+ (NSArray*)pushover:(NSString*)appID;
+ (NSArray*)pushbullet:(NSString*)appID;
+ (NSArray*)ifttt:(NSString*)appID;
+ (NSArray*)pusherReceiver:(NSString*)appID;
+ (NSArray*)wechat:(NSString*)appID;
+ (void)setPreferenceValue:(id)value
    forBuiltInServiceSpecifier:(PSSpecifier*)specifier;
+ (id)readBuiltInServicePreferenceValue:(PSSpecifier*)specifier;
+ (void)setPreferenceValue:(id)value forCustomSpecifier:(PSSpecifier*)specifier;
+ (id)readCustomPreferenceValue:(PSSpecifier*)specifier;
+ (void)setPreference:(CFStringRef)keyRef
                value:(CFPropertyListRef)val
         shouldNotify:(BOOL)shouldNotify;
+ (id)getPreference:(CFStringRef)keyRef;
+ (void)setPreferenceValue:(id)value forGlobalSpecifier:(PSSpecifier*)specifier;
+ (id)readGlobalPreferenceValue:(PSSpecifier*)specifier;
+ (NSArray*)globalAppList;
+ (void)setGlobalAppList:(NSArray*)appList;
+ (NSArray*)builtInServiceAppListForService:(NSString*)service;
+ (void)setBuiltInServiceAppList:(NSArray*)appList
                      forService:(NSString*)service;
+ (NSArray*)customServiceAppListForService:(NSString*)service;
+ (void)setCustomServiceAppList:(NSArray*)appList
                     forService:(NSString*)service;
@end
