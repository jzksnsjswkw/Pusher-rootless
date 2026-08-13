#import <Foundation/Foundation.h>

@class NSPushConfigSnapshot;

@interface NSPushServiceConfig : NSObject

@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly) BOOL isCustomService;
@property(nonatomic, readonly, copy) NSDictionary* rawPrefs;
@property(nonatomic, readonly, copy) NSArray* appList;
@property(nonatomic, readonly) BOOL appListIsBlacklist;
@property(nonatomic, readonly, copy) NSArray* sns;
@property(nonatomic, readonly) BOOL snsIsAnd;
@property(nonatomic, readonly) BOOL snsRequireANWithOR;
@property(nonatomic, readonly) NSInteger whenToPush;
@property(nonatomic, readonly) NSInteger whatNetwork;
@property(nonatomic, readonly, copy) NSDictionary* customApps;

+ (instancetype)configWithName:(NSString*)name
                      rawPrefs:(NSDictionary*)rawPrefs
               isCustomService:(BOOL)isCustomService;

- (NSPushServiceConfig*)effectiveConfigForAppID:(NSString*)appID;

@end

@interface NSPushConfigSnapshot : NSObject

@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly) NSInteger whenToPush;
@property(nonatomic, readonly) NSInteger whatNetwork;
@property(nonatomic, readonly) BOOL globalAppListIsBlacklist;
@property(nonatomic, readonly, copy) NSArray* globalAppList;
@property(nonatomic, readonly) BOOL snsIsAnd;
@property(nonatomic, readonly) BOOL snsRequireANWithOR;
@property(nonatomic, readonly, copy) NSDictionary* serviceConfigs;
@property(nonatomic, readonly, copy) NSArray* enabledServiceNames;

+ (instancetype)snapshotWithEnabled:(BOOL)enabled
                         whenToPush:(NSInteger)whenToPush
                        whatNetwork:(NSInteger)whatNetwork
           globalAppListIsBlacklist:(BOOL)globalAppListIsBlacklist
                      globalAppList:(NSArray*)globalAppList
                           snsIsAnd:(BOOL)snsIsAnd
                 snsRequireANWithOR:(BOOL)snsRequireANWithOR
                     serviceConfigs:(NSDictionary*)serviceConfigs
                enabledServiceNames:(NSArray*)enabledServiceNames;

@end

@interface NSPushPrefs : NSObject

+ (NSPushConfigSnapshot*)loadSnapshot;

@end
