#import "NSPushServicePrefs.h"

@implementation NSPushServicePrefsManager

static NSMutableDictionary<NSString*, NSPSharedSpecifierBuilder>* gBuilders;
static dispatch_once_t gBuildersToken;

+ (void)registerBuilder:(NSPSharedSpecifierBuilder)builder
             forService:(NSString*)service {
  dispatch_once(&gBuildersToken, ^{
    gBuilders = [NSMutableDictionary new];
  });
  if (service.length > 0 && builder) {
    gBuilders[service] = builder;
  }
}

+ (NSPSharedSpecifierBuilder)builderForService:(NSString*)service {
  dispatch_once(&gBuildersToken, ^{
    gBuilders = [NSMutableDictionary new];
  });
  return gBuilders[service];
}

@end