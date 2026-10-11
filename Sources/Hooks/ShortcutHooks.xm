// The pieces the Shortcut service needs from the Objective-C side.
//
// Two things live here, both of which Swift cannot express: an `@try` that
// catches an `NSException` (Swift's `do`/`catch` sees only Swift errors, so an
// exception raised inside a send unwinds into SpringBoard and takes it down),
// and the private-API calls that run a shortcut.

#import <Foundation/Foundation.h>

#pragma mark - Exception trap

/// Runs `block` inside an `@try`, swallowing an `NSException`.
///
/// Declared to Swift through `dlsym`, so the Preferences bundle — which
/// recompiles the Core sources but never runs a shortcut — links without it.
#ifdef __cplusplus
extern "C"
#endif
void PusherTrapExceptions(void (^block)(void)) {
  @try {
    block();
  } @catch (NSException *exception) {
    NSLog(@"[Pusher] caught %@: %@", exception.name, exception.reason);
  }
}

/// The private-API work for running a shortcut is in
/// `Sources/Core/Runtime/ShortcutRunner.m`: it swizzles a method, so it needs
/// `method_setImplementation` and `objc_msgSend` with scalar arguments.
