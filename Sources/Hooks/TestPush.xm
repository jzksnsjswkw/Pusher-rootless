// Test-push IPC endpoint.
//
// The Preferences bundle asks SpringBoard to send a test push over
// CPDistributedMessagingCenter (the only IPC available to an injected tweak
// without a helper process). The message handler itself is a one-liner into
// Swift: `NSPTestPush` builds the synthetic bulletin and hands it to the engine.

#import <Foundation/Foundation.h>
#import <AppSupport/CPDistributedMessagingCenter.h>

#import "Pusher-Swift.h"

@interface NSPTestPushServer : NSObject
@end

@implementation NSPTestPushServer

+ (void)load {
  // Only register in SpringBoard. The dylib also loads into Preferences
  // (matching the tweak's plist filter), and if both processes registered the
  // same message port, a respring race could let Preferences win and silently
  // swallow test pushes — the engine's BBServer reference is only wired up in
  // SpringBoard. Preferences can still *send* test messages, it just must not
  // host the server.
  if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) {
    [self sharedInstance];
  }
}

+ (instancetype)sharedInstance {
  static NSPTestPushServer *shared = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [NSPTestPushServer new];
  });
  return shared;
}

- (instancetype)init {
  if ((self = [super init])) {
    CPDistributedMessagingCenter *center =
        [CPDistributedMessagingCenter centerNamed:NSPushEngine.testPushCenterName];
    [center runServerOnCurrentThread];
    [center registerForMessageName:NSPushEngine.testPushMessageName
                            target:self
                          selector:@selector(handleMessageNamed:withUserInfo:)];
  }
  return self;
}

- (NSDictionary *)handleMessageNamed:(NSString *)name
                        withUserInfo:(NSDictionary *)userInfo {
  NSString *service = userInfo[@"service"];
  if (![service isKindOfClass:NSString.class] || service.length == 0) {
    return @{@"success": @NO};
  }
  return @{@"success": @([NSPTestPush sendTestPushToService:service])};
}

@end
