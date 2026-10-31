//
// imagent side of the SMS lookup.
//
// One job: answer "which number was message X received on", because this is the
// only process allowed to open the SMS database. Turning that number into a slot
// happens in SpringBoard, against CoreTelephony, so nothing about a SIM is read
// here.
//
// The transport is XPC through SandyXpc: the sandbox refuses a plain
// `bootstrap_look_up` from a tweak, and `CPDistributedMessagingCenter` — the first
// attempt — never had its handler invoked in this process at all. SandyXpc goes
// through the same mach service a system daemon would, which this daemon may use.
//
// There is no hook: the database row already records the receiving number, so an
// earlier version that hooked `smsMessageReceived:msgID:` was never needed.

#import <Foundation/Foundation.h>
#import <libSandyXpc.h>
#import <dlfcn.h>
#import <roothide.h>
#import <unistd.h>

/// A line to NSLog, tagged so it can be filtered for in Console.app.
///
/// The device has no `log` command, and a daemon's sandbox does not reliably grant
/// write access to any file this project could then read back — so the unified log
/// is the only channel that works in every case. `PusherSMS` in the message is what
/// makes the stream filterable.
static void SMSLog(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  NSLog(@"[PusherSMS] %@", line);
}

#import "PusherSMS-Swift.h"

static NSString *const kCenterName = @"com.jzksnsjswkw.pusher.sms";
static NSString *const kLookupMessage = @"lookup";

/// Applies this process's libSandy profile, widening the sandbox enough to
/// publish a mach service.
///
/// `bootstrap_check_in` is refused for a daemon that has not been given the
/// `mach-register` extension, and the refusal arrives as an exception out of
/// `MachXPCListener` rather than as a return code — which is why the profile is
/// applied before the listener is built and why the failure is logged rather than
/// asserted on.
///
/// `dlopen` rather than a link-time dependency: libSandy is a runtime optional. A
/// device without it should lose SMS metadata, not be unable to install.
static void ApplySandyProfile(void) {
  // `jbroot()` rather than a literal path: on roothide the jailbreak lives in a
  // directory whose name changes between jailbreaks, and this project's other
  // lookups all go through it for that reason. `@rpath` is not an option — it
  // resolves against the loading binary's rpaths, and a daemon has none of ours.
  void *handle = dlopen(jbroot("/usr/lib/libsandy.dylib"), RTLD_LAZY);
  if (!handle) {
    SMSLog(@"libsandy.dylib not found at %s: %s",
           jbroot("/usr/lib/libsandy.dylib"), dlerror());
    return;
  }
  int (*applyProfile)(const char *) =
      (int (*)(const char *))dlsym(handle, "libSandy_applyProfile");
  if (!applyProfile) {
    SMSLog(@"libSandy_applyProfile not found");
    dlclose(handle);
    return;
  }
  int status = applyProfile("PusherSMS");
  SMSLog(@"libSandy_applyProfile(PusherSMS) = %d", status);
}

/// Answers lookups: the message id in, the receiving number out.
@interface NSPSMSLookupServer : NSObject
- (NSDictionary *)onLookup:(NSString *)messageName userInfo:(NSDictionary *)userInfo;
@end

@implementation NSPSMSLookupServer

- (NSDictionary *)onLookup:(NSString *)messageName userInfo:(NSDictionary *)userInfo {
  SMSLog(@"lookup received: %@", userInfo[@"guid"]);
  NSString *guid = userInfo[@"guid"];
  if (![guid isKindOfClass:NSString.class] || guid.length == 0) {
    return @{@"found": @NO};
  }
  NSDictionary *row = [SMSStore receivingNumberForGuid:guid];
  SMSLog(@"lookup answer: %@", row);
  return row ?: @{@"found": @NO};
}

@end

static SandyXpcMessagingCenter *gCenter = nil;
static NSPSMSLookupServer *gServer = nil;

%ctor {
  @autoreleasepool {
    // Written before anything can fail, to the one path a daemon can always reach
    // when the jailbreak is rootless: its own container. `NSHomeDirectory()` is
    // what decides that, and it is empty until the process has one.
    SMSLog(@"boot, home=%@ tmp=%@", NSHomeDirectory(), NSTemporaryDirectory());
    // Diary of the startup, because the failure modes here are silent: a daemon
    // that never runs `runServer` looks exactly like one that does, from the
    // client side — the call simply never returns.
    SMSLog(@"ctor, pid %d", getpid());
    if (NSClassFromString(@"SandyXpcMessagingCenter") == Nil) {
      SMSLog(@"SandyXpcMessagingCenter is MISSING — is libSandyXpc installed?");
      return;
    }
    SMSLog(@"SandyXpcMessagingCenter found");

    // Deferred: a daemon's constructor runs before its run loop exists, and
    // `runServer` needs one to dispatch on.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          SMSLog(@"starting server on %@", kCenterName);
          // Every call below can throw, and an uncaught exception in a daemon is
          // `abort()` — which takes Messages down with it. `MachXPCListener` raises
          // when `bootstrap_check_in` is refused, and it is refused until a libSandy
          // profile widens this process's sandbox. Failing quietly is the only
          // acceptable outcome: no SMS metadata, but a working Messages app.
          SMSLog(@"deferred block entered, about to apply profile");
          ApplySandyProfile();
          SMSLog(@"profile applied, building listener");
          @try {
            gServer = [[NSPSMSLookupServer alloc] init];
            gCenter = [SandyXpcMessagingCenter centerNamed:kCenterName];
            SMSLog(@"center = %@", gCenter);
            [gCenter registerForMessageName:kLookupMessage
                                     target:gServer
                                   selector:@selector(onLookup:userInfo:)];
            SMSLog(@"registered, running server");
            [gCenter runServer];
            SMSLog(@"runServer returned — server is up");
          } @catch (NSException *exception) {
            SMSLog(@"runServer failed: %@ — %@",
                   exception.name, exception.reason);
          } @finally {
            SMSLog(@"deferred block finished");
          }
        });
  }
}
