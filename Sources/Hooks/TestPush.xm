// Test-push IPC endpoint.
//
// The Preferences bundle asks SpringBoard to send a test push over
// CPDistributedMessagingCenter (the only IPC available to an injected tweak
// without a helper process). The message handler itself is a one-liner into
// Swift: `NSPTestPush` builds the synthetic bulletin and hands it to the engine.

#import <Foundation/Foundation.h>
#import <AppSupport/CPDistributedMessagingCenter.h>

#import "Pusher-Swift.h"
#import "PusherBanner.h"

@interface NSPTestPushServer : NSObject
/// Publishes a composed notification onto the screen.
///
/// Nothing is forwarded and no service is involved: this is the notification
/// itself, drawn by the app it claims to come from. It exists because "does this
/// payload look right" cannot be answered by a form, and a banner with the real
/// app's icon and name is what the receiver's user actually sees.
///
/// The banner goes through `BBServer` in this process, so it also re-enters the
/// pipeline — a published notification is one Pusher forwards, which means a
/// configured service sends it too. That is intended: it is the same path a real
/// notification takes.
- (NSDictionary *)displayDraftJSON:(NSString *)draftJSON;

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
    return @{@"hasInstance": @NO};
  }
  // `draftJSON` carries the notification the user composed, as JSON: across this
  // boundary only property-list types survive, and JSON is the one shape both
  // sides can read without naming a class. Absent means the fixed test
  // notification.
  id draft = userInfo[@"draftJSON"];
  NSString *draftJSON = [draft isKindOfClass:NSString.class] ? draft : nil;

  // `display` publishes the composed notification onto the screen as if the app
  // named in it had sent it. This is a separate step from the push: the push asks
  // "does my credential work", this asks "does this notification look right", and
  // the second question is only answered by the notification itself.
  // Published here rather than in Swift: `BBServer` lives in this process, and
  // the symbol is only linked into the tweak — compiling that call into the
  // Preferences bundle would make it an unresolved reference there, since the
  // bundle deliberately has no copy of this file.
  // Shown and forwarded, in that order, through the one send path every test
  // uses. The banner answers "does this look right"; `sendTestPushToService:`
  // answers "does my instance take it" — and it is the same call the fixed test
  // button and a hook's Run make, so a composed notification cannot behave
  // differently from them.
  //
  // The publish is what puts it on the screen; it re-enters the hook as a live
  // bulletin, which is why the context is marked composed — see
  // `BulletinAdapter.wasPresented`.
  if ([userInfo[@"display"] boolValue]) {
    NSDictionary *shown = [self displayDraftJSON:draftJSON];
    // Nothing is sent from here. The published notification re-enters the engine
    // as a real bulletin, and the engine forwards it to every enabled instance —
    // which is the behaviour a notification the user composed should have. Sending
    // as well is what made an enabled instance receive it twice.
    //
    // The one case that needs the push: publishing failed, so no bulletin exists
    // and no forward will happen. The reply says which of the two it was, and the
    // page reports it.
    if ([shown[@"displayed"] boolValue]) {
      return @{@"displayed": @YES, @"hasInstance": @YES};
    }
    NSMutableDictionary *reply =
        [@{@"displayed": @NO,
           @"reason": shown[@"reason"] ?: @"SpringBoard could not publish"} mutableCopy];
    [reply addEntriesFromDictionary:
        [NSPTestPush sendTestPushToService:service draftJSON:draftJSON]];
    return reply;
  }
  // The reply carries two facts, not one: whether the instance exists, and
  // whether a request could be built from its settings. "Delivered" is not among
  // them — that answer arrives on the transport's own queue, long after.
  return [NSPTestPush sendTestPushToService:service draftJSON:draftJSON];
}

- (NSDictionary *)displayDraftJSON:(NSString *)draftJSON {
  NSDictionary *draft = [NSPTestPush draftFields:draftJSON];
  if (draft == nil) {
    return @{@"displayed": @NO, @"reason": @"No notification to show"};
  }
  NSString *subtitle = draft[@"subtitle"];
  NSString *slotText = draft[@"simSlot"];
  long long slot = [slotText respondsToSelector:@selector(longLongValue)]
      ? [slotText longLongValue] : 0;
  BOOL shown = PusherPublishBanner(draft[@"appID"],
                                   draft[@"title"],
                                   subtitle.length > 0 ? subtitle : nil,
                                   draft[@"message"],
                                   draft[@"attachmentPath"],
                                   slot,
                                   draft[@"simPhone"],
                                   draft[@"simLabel"]);
  if (shown) { return @{@"displayed": @YES}; }
  NSString *why = PusherPublishBannerFailure;
  return @{@"displayed": @NO,
           @"reason": why.length > 0 ? why : @"SpringBoard could not publish"};
}

@end
