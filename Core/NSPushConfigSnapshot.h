#import <Foundation/Foundation.h>

@class NSPushServiceConfig;

@interface NSPushConfigSnapshot : NSObject

@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly) NSInteger whenToPush;
@property(nonatomic, readonly) NSInteger whatNetwork;
@property(nonatomic, readonly) BOOL globalAppListIsBlacklist;
@property(nonatomic, readonly, copy) NSArray* globalAppList;
@property(nonatomic, readonly) BOOL snsIsAnd;
@property(nonatomic, readonly) BOOL snsRequireANWithOR;
@property(nonatomic, readonly, copy) NSDictionary* globalSNS;
@property(nonatomic, readonly, copy) NSDictionary* serviceConfigs;
@property(nonatomic, readonly, copy) NSArray* enabledServiceNames;

+ (instancetype)snapshotWithEnabled:(BOOL)enabled
                         whenToPush:(NSInteger)whenToPush
                        whatNetwork:(NSInteger)whatNetwork
           globalAppListIsBlacklist:(BOOL)globalAppListIsBlacklist
                      globalAppList:(NSArray*)globalAppList
                           snsIsAnd:(BOOL)snsIsAnd
                 snsRequireANWithOR:(BOOL)snsRequireANWithOR
                          globalSNS:(NSDictionary*)globalSNS
                     serviceConfigs:(NSDictionary*)serviceConfigs
                enabledServiceNames:(NSArray*)enabledServiceNames;

@end
