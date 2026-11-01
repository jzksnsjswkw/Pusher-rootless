#import "PusherBanner.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Calling a private method with a variable number of arguments.
//
// The publisher has three signatures across the iOS line and only one is
// installed at a time. `performSelector:` stops at two arguments, and a category
// cannot be declared for a class that no header in this build defines — so the
// call goes through the message send itself, typed to the exact signature that
// was just checked for. That is the one place in this file where a cast is doing
// real work rather than satisfying the compiler.
typedef void (*Publish1)(id, SEL, id, unsigned long long);
typedef void (*Publish2)(id, SEL, id, unsigned long long, BOOL);
typedef void (*Publish0)(id, SEL, id, unsigned long long);

/// The attachment builder, implemented in Swift.
///
/// Declared here, not in a header: this file is Objective-C, and the generated
/// `Pusher-Swift.h` that defines the class is only produced after Swift compiles —
/// which is after this file. A forward declaration of the one method is what lets
/// both orderings work, and it keeps the definition in a single place: a hand-copied
/// second implementation here is what gave the composed banner a different
/// identifier than the pipeline's, and a mismatched identifier is an attachment that
/// does not load.
@interface NSPBulletinAttachment : NSObject
+ (id)metadataForPath:(NSString *)path;
@end

/// The destinations every real notification uses.
///
/// `0x0D` reaches the lock screen, the banner area and Notification Center. A
/// literal rather than an enum: the destination bits are not declared in any
/// header this build has, and they have not changed across the iOS versions this
/// targets.
static const unsigned long long kPusherDestinations = 0x0D;

/// The queue `BBServer` requires publishing from.
///
/// `-[BBServer _sectionInfoForSectionID:effective:]` asserts it runs on this one,
/// and publishing reaches it — `_updateShowsMessagePreviewForBulletin:` calls it
/// while the bulletin is being prepared. Neither the main thread nor a background
/// queue satisfies the assertion, so publishing from anywhere else kills
/// SpringBoard.
///
/// The queue is a private global, `__BBServerQueue`, with no accessor. Read once
/// through `dlsym` and kept: it is a `__weak` global, so a local read could be
/// collected between the read and the call, while this strong copy pins it.
static dispatch_queue_t PusherServerQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    void *handle = dlopen(NULL, RTLD_GLOBAL);
    if (handle == NULL) { return; }
    // The symbol is `__weak`, so its address holds a weak reference. Reading it
    // into a strong local under ARC would work, but through a raw pointer the
    // value has to be retained explicitly.
    dispatch_queue_t __weak *pointer = (dispatch_queue_t __weak *)dlsym(handle, "__BBServerQueue");
    if (pointer != NULL) { queue = *pointer; }
    dlclose(handle);
  });
  return queue;
}


/// Why the last publish failed, or `nil` when it worked.
///
/// A `BOOL` return is enough for the caller to report failure but not to say
/// which step failed, and every step here depends on a private class that only
/// some iOS versions have. The reason is carried out-of-band so the page that
/// asked can show it instead of a generic message.
NSString *PusherPublishBannerFailure = nil;

// The property names `BBBulletinRequest` takes. KVC rather than declared
// properties, because the vendored header declares none of them on the request
// class — only on `BBBulletin`, which is not what gets published.
/// An attachment for a file on disk.
///
/// Two initializers exist and only one is installed per iOS version: the typed one
/// from iOS 14, and the older UUID one. The Core pipeline already builds these for
/// real notifications and picks between them the same way, so the shape sent here
/// is the shape SpringBoard draws for a genuine attachment — `type: 1` is an
/// image, `public.png` the type hint, and `thumbnailHidden`/`hiddenFromDefaultExpandedView`
/// match what a real notification carries.
static BOOL PusherSetIfPossible(id object, NSString *key, id value) {
  @try {
    [object setValue:value forKey:key];
    return YES;
  } @catch (NSException *exception) {
    return NO;
  }
}

/// Publishes on the main thread.
///
/// Publishing is not a leaf call: `BBServer` hands the bulletin to the hook that
/// forwards notifications, which rebuilds a context, and building a context asks
/// `BBServer` for the app's section info — a method that asserts it runs on the
/// main queue. Called from the distributed-messaging thread, that assertion fires
/// `SIGTRAP` and SpringBoard restarts into safe mode.
///
/// So the whole publish runs on the main thread. The sender is a different
/// process waiting on a reply, so this blocks it rather than the UI: the main
/// thread of SpringBoard is inside its run loop and free to take the work.
static BOOL PusherPublishOnMain(NSString *sectionID,
                                NSString *title,
                                NSString *subtitle,
                                NSString *message,
                                NSString *attachmentPath,
                                long long simSlot,
                                NSString *simPhone,
                                NSString *simLabel,
                                NSString *ranHook);

BOOL PusherPublishBanner(NSString *sectionID,
                         NSString *title,
                         NSString *subtitle,
                         NSString *message,
                         NSString *attachmentPath,
                         long long simSlot,
                         NSString *simPhone,
                         NSString *simLabel,
                         NSString *ranHook) {
  // Cleared before every attempt. It is a module-level variable because the reason
  // has to outlive the call, and a reason left over from a previous failure made
  // every later publish report that failure — the page was reading an answer to a
  // question asked minutes ago.
  PusherPublishBannerFailure = nil;
  if (sectionID.length == 0) {
    PusherPublishBannerFailure = @"No app to show a notification for";
    return NO;
  }
  return PusherPublishOnMain(sectionID, title, subtitle, message, attachmentPath,
                             simSlot, simPhone, simLabel, ranHook);
}

/// Whether SpringBoard knows this app well enough to put a notification under it.
///
/// A section is what carries an app's notification settings and its icon.
/// Publishing to an app that has none is *accepted* and then dropped — no
/// exception, no notification, and no reply that says why. It happens for an app
/// that never asked for notification permission, which is common enough that a
/// test for one looks broken.
static BOOL PusherHasSection(id server, NSString *sectionID) {
  SEL lookup = @selector(_sectionInfoForSectionID:effective:);
  if (![server respondsToSelector:lookup]) {
    // Cannot ask, so assume yes: refusing every publish on a system where the
    // selector is missing would be worse than trying.
    return YES;
  }
  @try {
    id info = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(server, lookup, sectionID, YES);
    return info != nil;
  } @catch (NSException *exception) {
    // The selector asserts it runs on the server's queue, which the caller
    // guarantees — but a wrong guess here should not stop the notification.
    return YES;
  }
}

static BOOL PusherPublishOnMain(NSString *sectionID,
                                NSString *title,
                                NSString *subtitle,
                                NSString *message,
                                NSString *attachmentPath,
                                long long simSlot,
                                NSString *simPhone,
                                NSString *simLabel,
                                NSString *ranHook) {

  id server = Nil;
  Class serverClass = NSClassFromString(@"BBServer");
  if (serverClass == Nil) {
    NSLog(@"[Pusher] publish: BBServer class not found");
    return NO;
  }
  // Two ways to reach it, because neither alone is reliable. `BBServer` is not
  // documented as a singleton, so `sharedInstance` may not exist; while the
  // adapter's reference is `weak` and set only once the `_addObserver:` hook has
  // run, so it can still be nil here.
  server = [serverClass respondsToSelector:@selector(sharedInstance)]
      ? ((id (*)(id, SEL))objc_msgSend)(serverClass, @selector(sharedInstance))
      : nil;
  if (server == Nil) {
    // The pipeline's own reference, set by the publish hook in this process.
    Class adapter = NSClassFromString(@"NSPBulletinAdapter");
    if (adapter != Nil) {
      server = ((id (*)(id, SEL))objc_msgSend)(
          adapter, @selector(sharedInstance));
      if (server != Nil) {
        server = ((id (*)(id, SEL))objc_msgSend)(server, @selector(server));
      }
    }
  }
  if (server == Nil) {
    // Reported rather than logged: the answer goes back to the page that asked,
    // where it is the only way the user finds out which of the two ways of
    // reaching the server is missing on this iOS line.
    PusherPublishBannerFailure = @"No BBServer to publish through";
    return NO;
  }

  Class bulletinClass = NSClassFromString(@"BBBulletinRequest");
  if (bulletinClass == Nil) { bulletinClass = NSClassFromString(@"BBBulletin"); }
  if (bulletinClass == Nil) {
    PusherPublishBannerFailure = @"No BBBulletinRequest class";
    return NO;
  }

  id bulletin = ((id (*)(id, SEL))objc_msgSend)(
      ((id (*)(id, SEL))objc_msgSend)(bulletinClass, @selector(alloc)),
      @selector(init));
  if (bulletin == Nil) { return NO; }

  // Every field is optional except the section: a notification with no body is
  // legitimate (a title-only alert is exactly the case the WxPusher work had to
  // handle), while a section SpringBoard cannot resolve draws as "Unknown App".
  PusherSetIfPossible(bulletin, @"sectionID", sectionID);

  // Three identifiers, and all three are required.
  //
  // `bulletinID` is the one that becomes the `UNNotificationRequest`'s identifier
  // when SpringBoard hands the published bulletin to UserNotificationsUI — with it
  // missing, `_initWithIdentifier:content:trigger:destinations:` raises and the
  // exception takes SpringBoard down. `recordID` is what a withdraw keys on. And
  // `publisherBulletinID` is the stable one this tweak groups its log and its
  // replay check on, which a real notification always carries.
  NSString *identifier = [[NSUUID UUID] UUIDString];
  PusherSetIfPossible(bulletin, @"bulletinID", identifier);
  PusherSetIfPossible(bulletin, @"recordID", identifier);
  PusherSetIfPossible(bulletin, @"publisherBulletinID", identifier);
  PusherSetIfPossible(bulletin, @"title", title ?: @"");
  if (subtitle.length > 0) { PusherSetIfPossible(bulletin, @"subtitle", subtitle); }
  PusherSetIfPossible(bulletin, @"message", message ?: @"");
  PusherSetIfPossible(bulletin, @"date", [NSDate date]);

  // A real notification carries a default action, which is what a tap launches.
  // Without one the `UNNotificationContent` built from this bulletin has nothing
  // to route a tap to.
  Class actionClass = NSClassFromString(@"BBAction");
  if (actionClass != Nil) {
    SEL factory = @selector(actionWithLaunchBundleID:callblock:);
    if ([actionClass respondsToSelector:factory]) {
      id action = ((id (*)(id, SEL, id, id))objc_msgSend)(
          actionClass, factory, sectionID, nil);
      if (action != nil) { PusherSetIfPossible(bulletin, @"defaultAction", action); }
    }
  }

  // `date` alone does not make SpringBoard present it: a bulletin is only shown
  // when it is interruptive. Stamping the interrupt here also satisfies the
  // pipeline's own "was this presented" check, which reads `lastInterruptDate`
  // to tell a real notification from a queued replay.
  PusherSetIfPossible(bulletin, @"lastInterruptDate", [NSDate date]);

    // A SIM the user picked.
  //
  // A real message's card is resolved by asking `imagent` which row the
  // notification's GUID points at — a composed notification has no row, so that
  // lookup returns nothing. The choice therefore travels on the bulletin's
  // context, which is where the adapter already reads an SMS notification's
  // identifiers from; see `BulletinAdapter` for the other end.
  // The context is always written, because it also carries the marker that says
  // this bulletin is a composed one. Without it the notification reaches the hook
  // as an ordinary live one and the app rules filter it — which is the opposite of
  // what a test is for.
  NSMutableDictionary *context = [NSMutableDictionary dictionary];
  context[@"PusherComposed"] = @YES;
  // The hook a Run already executed in its editor. Read back by the adapter so the
  // pipeline skips that phase — one notification edited twice is a hook that
  // appends text appearing to append it twice.
  if (ranHook.length > 0) { context[@"PusherRanHook"] = ranHook; }
  if (simSlot > 0) {
    context[@"PusherSIMSlot"] = @(simSlot);
    if (simPhone.length > 0) { context[@"PusherSIMPhone"] = simPhone; }
    if (simLabel.length > 0) { context[@"PusherSIMLabel"] = simLabel; }
  }
  PusherSetIfPossible(bulletin, @"context", context);

  if (attachmentPath.length > 0) {
    // The one attachment builder, in Swift: a hand-copied second version here is
    // what gave the composed banner a different identifier than the pipeline's,
    // and a mismatched identifier is an attachment that does not load.
    //
    // A failure to load is reported rather than fatal: the notification is the
    // thing being tested, and dropping it because the picture would not load
    // answers a question nobody asked. The page shows the reason.
    id metadata = nil;
    @try {
      metadata = [NSPBulletinAttachment metadataForPath:attachmentPath];
    } @catch (NSException *exception) {
      metadata = nil;
    }
    if (metadata != nil) {
      PusherSetIfPossible(bulletin, @"primaryAttachment", metadata);
    } else {
      NSLog(@"[Pusher] publish: attachment could not be built from %@", attachmentPath);
      PusherPublishBannerFailure =
          @"The attachment could not be loaded; the notification was not shown";
      return NO;
    }
  }

  dispatch_queue_t target = PusherServerQueue();
    void (^publish)(void) = ^{

      // An app with no section cannot receive a notification, and publishing to
      // one is silently dropped. Said out loud so the page can report it, rather
      // than the notification simply not appearing.
      if (!PusherHasSection(server, sectionID)) {
        // An English key: the page localises it, and the app id is interpolated
        // after the lookup so the Chinese can word the sentence its own way.
        PusherPublishBannerFailure = [NSString stringWithFormat:
            @"No notification permission||%@", sectionID];
        return;
      }

      SEL request = @selector(publishBulletinRequest:destinations:);
      SEL plain = @selector(publishBulletin:destinations:);
      SEL legacy = @selector(publishBulletin:destinations:alwaysToLockScreen:);
      if ([server respondsToSelector:request]) {
        ((Publish0 (*)(id, SEL, id, unsigned long long))objc_msgSend)(
            server, request, bulletin, kPusherDestinations);
      } else if ([server respondsToSelector:legacy]) {
        ((Publish1 (*)(id, SEL, id, unsigned long long, BOOL))objc_msgSend)(
            server, legacy, bulletin, kPusherDestinations, YES);
      } else if ([server respondsToSelector:plain]) {
        ((Publish2 (*)(id, SEL, id, unsigned long long))objc_msgSend)(
            server, plain, bulletin, kPusherDestinations);
      } else {
        PusherPublishBannerFailure = @"No publishing selector on BBServer";
      }
    };

    if (target != NULL) {
      // The queue the server demands. `dispatch_sync` from here blocks the waiting
      // IPC caller, not SpringBoard's UI.
      //
      // Caught, because publishing is not a leaf: SpringBoard resolves the
      // section's icon while drawing the notification, and an icon it cannot make
      // raises rather than returning nil. Uncaught, that exception travels back
      // through the messaging centre and the notification simply never appears —
      // with the forward still sent, since that is a separate call.
      @try {
        dispatch_sync(target, publish);
      } @catch (NSException *exception) {
        PusherPublishBannerFailure = [NSString
            stringWithFormat:@"Publishing raised %@: %@",
                             exception.name, exception.reason];
        return NO;
      }
    } else {
      // Without the private symbol there is no queue to satisfy. Publishing from
      // any thread would trip the same assertion, so the answer is "no" rather
      // than a crash.
      PusherPublishBannerFailure = @"No __BBServerQueue to publish on";
    }

  if (PusherPublishBannerFailure != nil) { return NO; }
  return YES;
}
