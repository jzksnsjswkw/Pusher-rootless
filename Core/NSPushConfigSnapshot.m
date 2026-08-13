#import "NSPushConfigSnapshot.h"

@interface NSPushConfigSnapshot ()
@property(nonatomic, readwrite) BOOL enabled;
@property(nonatomic, readwrite) NSInteger whenToPush;
@property(nonatomic, readwrite) NSInteger whatNetwork;
@property(nonatomic, readwrite) BOOL globalAppListIsBlacklist;
@property(nonatomic, readwrite, copy) NSArray* globalAppList;
@property(nonatomic, readwrite) BOOL snsIsAnd;
@property(nonatomic, readwrite) BOOL snsRequireANWithOR;
@property(nonatomic, readwrite, copy) NSDictionary* globalSNS;
@property(nonatomic, readwrite, copy) NSDictionary* serviceConfigs;
@property(nonatomic, readwrite, copy) NSArray* enabledServiceNames;
@end

@implementation NSPushConfigSnapshot

+ (instancetype)snapshotWithEnabled:(BOOL)enabled
                         whenToPush:(NSInteger)whenToPush
                        whatNetwork:(NSInteger)whatNetwork
           globalAppListIsBlacklist:(BOOL)globalAppListIsBlacklist
                      globalAppList:(NSArray*)globalAppList
                           snsIsAnd:(BOOL)snsIsAnd
                 snsRequireANWithOR:(BOOL)snsRequireANWithOR
                          globalSNS:(NSDictionary*)globalSNS
                     serviceConfigs:(NSDictionary*)serviceConfigs
                enabledServiceNames:(NSArray*)enabledServiceNames {
  NSPushConfigSnapshot* snapshot = [NSPushConfigSnapshot new];
  snapshot.enabled = enabled;
  snapshot.whenToPush = whenToPush;
  snapshot.whatNetwork = whatNetwork;
  snapshot.globalAppListIsBlacklist = globalAppListIsBlacklist;
  snapshot.globalAppList = globalAppList;
  snapshot.snsIsAnd = snsIsAnd;
  snapshot.snsRequireANWithOR = snsRequireANWithOR;
  snapshot.globalSNS = globalSNS;
  snapshot.serviceConfigs = serviceConfigs;
  snapshot.enabledServiceNames = enabledServiceNames;
  return snapshot;
}

@end
