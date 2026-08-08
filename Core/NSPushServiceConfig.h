#import <Foundation/Foundation.h>

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
