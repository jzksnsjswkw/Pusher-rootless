// Running one of the user's Shortcuts, silently.
//
// There is no supported API for this, and the route that works is narrower than
// it looks. It was found by disassembling SpringCuts (a tweak that does the same
// thing) and then verified piece by piece on the device:
//
//   1. `WFWidgetWorkflowRunnerClient` runs a shortcut given only its
//      *identifier* — the daemon resolves the workflow itself, so the caller
//      never needs the shortcuts database. That matters enormously here:
//      `/var/mobile/Library/Shortcuts/Shortcuts.sqlite` is protected data that
//      SpringBoard cannot read, which is what killed every attempt to run a
//      shortcut by loading its contents.
//
//   1b. iOS 17 added a parameter to that initializer
//      (`initWithWorkflowIdentifier:location:`). Both spellings are tried, so
//      the same build works on either; see the call site for why adapting the
//      call beats installing the old method on the system class.
//
//   2. `presentationMode = 3` makes the run silent: no UI, and the Shortcuts app
//      is not brought forward.
//
//   3. Input does *not* travel through `runRequest`. `setCachedInput:` looks like
//      it should work and silently does nothing — the request is serialized to
//      the daemon and the input is dropped on the way. What works is replacing
//      `-[WFWorkflowRunRequest archivedInput]`, which the daemon calls to obtain
//      the input it hands the workflow. That is why this file swizzles a private
//      method.
//
// Lives in this directory so that both targets can compile it with a relative
// path: the tweak (which runs the shortcut) and the Preferences bundle (which
// recompiles the Core sources and so needs the symbols to link, even though it
// never sends anything).

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

/// Tells our run requests apart from SpringBoard's own widget runs, which go
/// through the same class.
static const void *PusherShortcutMarker = &PusherShortcutMarker;

/// Input to hand to the next shortcut run, keyed by workflow identifier.
///
/// A dictionary rather than one slot because two instances may fire at once and
/// the daemon may ask for either.
static NSMutableDictionary<NSString *, NSString *> *PusherShortcutInputs(void) {
  static NSMutableDictionary *inputs = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ inputs = [NSMutableDictionary dictionary]; });
  return inputs;
}

/// `-[WFWorkflowRunRequest archivedInput]`, replaced.
///
/// Returns a `WFContentCollection` wrapping the input registered for this
/// request's shortcut, and calls the original for anything else — SpringBoard
/// runs widget shortcuts through this class too, so answering unconditionally
/// would corrupt them.
static id (*PusherOriginalArchivedInput)(id, SEL);

static id PusherArchivedInput(id self, SEL _cmd) {
  @try {
    NSString *identifier = objc_getAssociatedObject(self, PusherShortcutMarker);
    NSString *input = identifier ? PusherShortcutInputs()[identifier] : nil;
    if (input) {
      // One input belongs to one run.
      [PusherShortcutInputs() removeObjectForKey:identifier];

      Class collectionClass = NSClassFromString(@"WFContentCollection");
      Class itemClass = NSClassFromString(@"WFContentItem");
      if (collectionClass && itemClass) {
        id collection = [[collectionClass alloc] init];
        id item = ((id (*)(id, SEL, id))objc_msgSend)(
            itemClass, sel_registerName("itemWithObject:"), input);
        if (item) {
          ((void (*)(id, SEL, id))objc_msgSend)(
              collection, sel_registerName("addItem:"), item);
          NSError *error = nil;
          NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:collection
                                                   requiringSecureCoding:YES
                                                                   error:&error];
          if (archived) return archived;
          NSLog(@"[Pusher] Shortcut input archiving failed: %@", error);
        }
      }
    }
  } @catch (NSException *exception) {
    NSLog(@"[Pusher] Shortcut input injection failed: %@", exception.reason);
  }
  return PusherOriginalArchivedInput ? PusherOriginalArchivedInput(self, _cmd) : nil;
}

/// Installs the swizzle. Safe to call more than once.
static void PusherInstallShortcutInputHook(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Class requestClass = NSClassFromString(@"WFWorkflowRunRequest");
    if (!requestClass) return;
    Method method = class_getInstanceMethod(requestClass, sel_registerName("archivedInput"));
    if (!method) return;
    PusherOriginalArchivedInput = (id (*)(id, SEL))method_getImplementation(method);
    method_setImplementation(method, (IMP)PusherArchivedInput);
  });
}

/// Shortcuts on this device as `name` → `identifier`.
///
/// Asked of the XPC service rather than the shortcuts database, which
/// SpringBoard cannot read. Returns `nil` if the daemon did not answer.
static NSDictionary<NSString *, NSString *> *PusherShortcutMap(void) {
  NSMutableDictionary *found = [NSMutableDictionary dictionary];
  @try {
    Class clientClass = NSClassFromString(@"VCVoiceShortcutClient");
    if (!clientClass) return nil;
    id client = ((id (*)(id, SEL))objc_msgSend)(clientClass, sel_registerName("standardClient"));
    if (!client) return nil;

    __block BOOL replied = NO;
    void (^completion)(id, NSError *) = ^(id shortcuts, NSError *error) {
      @try {
        for (id shortcut in shortcuts) {
          NSString *name = ((id (*)(id, SEL))objc_msgSend)(shortcut, sel_registerName("shortcutName"));
          NSString *identifier = ((id (*)(id, SEL))objc_msgSend)(shortcut, sel_registerName("identifier"));
          if (name.length && identifier.length) found[name] = identifier;
        }
      } @catch (NSException *exception) {
      }
      replied = YES;
    };

    SEL selector = sel_registerName("getVoiceShortcutsWithCompletion:");
    NSMethodSignature *signature = [client methodSignatureForSelector:selector];
    if (!signature) return nil;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = client;
    invocation.selector = selector;
    [invocation setArgument:&completion atIndex:2];
    [invocation invoke];

    // The reply is asynchronous. Waiting costs little and removes a race that
    // would otherwise show up as "shortcut not found" on a cold daemon.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!replied && [deadline timeIntervalSinceNow] > 0) {
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (!replied) return nil;
  } @catch (NSException *exception) {
    return nil;
  }
  return found;
}

NSString *PusherRunShortcut(NSString *name, NSString *input) {
  @try {
    PusherInstallShortcutInputHook();

    NSDictionary<NSString *, NSString *> *shortcuts = PusherShortcutMap();
    if (!shortcuts) return @"cannot list shortcuts";
    NSString *identifier = shortcuts[name];
    if (!identifier) {
      return [NSString stringWithFormat:@"no shortcut named \"%@\"", name];
    }

    Class runnerClass = NSClassFromString(@"WFWidgetWorkflowRunnerClient");
    if (!runnerClass) return @"WFWidgetWorkflowRunnerClient not found";

    // Two spellings, because iOS 17 added a parameter to this initializer
    // (`initWithWorkflowIdentifier:location:`), and a missing one returns a
    // runner that never starts. Which is in effect is asked of the class rather
    // than assumed from a version check: the same build has to work on both, and
    // a version comparison would need updating for every future release anyway.
    //
    // Adapting the call rather than adding the old method back to the class —
    // which is what SpringCuts' compatibility shim does — keeps the change on
    // our side of the boundary: no method with `init` ownership semantics is
    // installed on a system class, and on iOS 16 the first spelling still wins
    // and nothing about this call changes.
    SEL initSelector = sel_registerName("initWithWorkflowIdentifier:");
    BOOL needsLocation = NO;
    if (![runnerClass instancesRespondToSelector:initSelector]) {
      initSelector = sel_registerName("initWithWorkflowIdentifier:location:");
      needsLocation = YES;
    }
    if (![runnerClass instancesRespondToSelector:initSelector]) {
      return @"WFWidgetWorkflowRunnerClient cannot be created by identifier";
    }
    // Held in a variable: assigning an +alloc result straight to
    // NSInvocation's unsafe-unretained target lets ARC release it too early.
    id allocated = [runnerClass alloc];
    NSMethodSignature *initSignature = [runnerClass instanceMethodSignatureForSelector:initSelector];
    NSInvocation *initInvocation = [NSInvocation invocationWithMethodSignature:initSignature];
    initInvocation.target = allocated;
    initInvocation.selector = initSelector;
    [initInvocation setArgument:&identifier atIndex:2];
    if (needsLocation) {
      // No location: this is not a widget placement, and the runner accepts 0.
      long long location = 0;
      [initInvocation setArgument:&location atIndex:3];
    }
    [initInvocation invoke];
    __unsafe_unretained id runner = nil;
    [initInvocation getReturnValue:&runner];
    if (!runner) return @"runner creation failed";

    id request = ((id (*)(id, SEL))objc_msgSend)(runner, sel_registerName("runRequest"));
    if (request) {
      if (input.length > 0) {
        PusherShortcutInputs()[identifier] = input;
        objc_setAssociatedObject(request, PusherShortcutMarker, identifier,
                                 OBJC_ASSOCIATION_RETAIN);
      }
      // Scalar setters go through objc_msgSend directly: `performSelector:`
      // boxes the value as an object and ARC then retains it. That mistake is
      // what killed this feature's first build.
      ((void (*)(id, SEL, id))objc_msgSend)(
          request, sel_registerName("setRunSource:"), @"pusher");
      ((void (*)(id, SEL, unsigned long long))objc_msgSend)(
          request, sel_registerName("setPresentationMode:"), 3ULL);
    }

    ((void (*)(id, SEL))objc_msgSend)(runner, sel_registerName("start"));
    return nil;
  } @catch (NSException *exception) {
    return [NSString stringWithFormat:@"%@", exception.reason];
  }
}

NSArray<NSString *> *PusherShortcutNames(void) {
  NSDictionary<NSString *, NSString *> *shortcuts = PusherShortcutMap();
  if (!shortcuts) return @[];
  return [shortcuts.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}
