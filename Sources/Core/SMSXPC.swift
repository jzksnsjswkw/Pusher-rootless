import Foundation

/// The client half of the SMS lookup, over XPC.
///
/// `SandyXpcMessagingCenter` is Objective-C and its header sits in
/// `$(THEOS)/include`, which the Swift sources do not import — so the class is
/// reached by name and only the two calls this project makes are declared here.
/// That keeps the library out of every other translation unit, and keeps this file
/// the one place to change if the API moves.
enum SMSXPC {
    /// The name the service is published under, and the message it answers.
    ///
    /// Both are compile-time constants in one place: `imagent` registers the same
    /// name from the other side.
    static let centerName = "com.jzksnsjswkw.pusher.sms"
    static let messageName = "lookup"

    /// Asks `imagent` which number a message was received on.
    ///
    /// `nil` when the daemon does not answer, which is a miss rather than an
    /// error: the caller is decorating a push that is already going out.
    /// How long to wait before deciding the daemon is not going to answer.
    ///
    /// SandyXpc's send waits on a semaphore with no deadline at all. Called from
    /// SpringBoard's main thread — which is where a notification is handled — that
    /// is an unbounded block on the process that draws the screen, and the symptom
    /// is the whole device freezing rather than one lookup failing.
    static let timeout: TimeInterval = 1.5

    static func lookup(guid: String) -> [String: Any]? {
        guard !guid.isEmpty else { return nil }
        guard let center = makeCenter() else {
            PusherLog.info("[PusherSMS] client: SandyXpcMessagingCenter unavailable")
            return nil
        }
        typealias Send = @convention(c) (
            AnyObject, Selector, NSString, NSDictionary, NSErrorPointer
        ) -> NSDictionary?
        let selector = NSSelectorFromString("sendMessageAndReceiveReplyName:userInfo:error:")
        guard let method = class_getInstanceMethod(type(of: center), selector)
        else { return nil }
        let send = unsafeBitCast(method_getImplementation(method), to: Send.self)
        var error: NSError?
        // The call itself runs off the caller's thread. `send` waits on a
        // semaphore with no deadline of its own, so an unanswered one holds its
        // thread forever and takes the connection with it.
        //
        // Timed out, the connection is dropped rather than reused: that is what
        // makes the blocked `send` return, and it stops the next lookup from
        // queuing behind a connection that is already stuck. Without this a burst
        // of ten messages while `imagent` is starting up leaked ten threads and
        // ten mach connections, once per message, for as long as the device ran.
        let done = DispatchSemaphore(value: 0)
        var box: [String: Any]?
        var timedOut = false
        DispatchQueue.global(qos: .utility).async {
            let reply = send(
                center, selector, messageName as NSString,
                ["guid": guid] as NSDictionary, &error
            )
            box = reply as? [String: Any]
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
        }
        if timedOut {
            PusherLog.info("[PusherSMS] client: timeout after \(timeout)s, dropping the connection")
            // Rebuilt on the next lookup. The thread blocked inside the old send
            // is released when the connection it is waiting on goes away.
            lock.lock()
            cached = nil
            lock.unlock()
            return nil
        }
        return box
    }

    /// Guards ``cached``, which is read on every lookup and replaced from the
    /// utility queue after a timeout.
    private static let lock = NSLock()


    /// The client side, made once.
    ///
    /// `centerNamed:` builds a connection lazily, and reusing it keeps repeated
    /// lookups from paying for a new mach port each time.
    private static var cached: AnyObject?

    private static func makeCenter() -> AnyObject? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let cls = NSClassFromString("SandyXpcMessagingCenter") as? NSObject.Type
        else { return nil }
        let selector = NSSelectorFromString("centerNamed:")
        guard cls.responds(to: selector) else { return nil }
        typealias Factory = @convention(c) (AnyObject, Selector, NSString) -> AnyObject?
        let factory = unsafeBitCast(cls.method(for: selector), to: Factory.self)
        cached = factory(cls, selector, centerName as NSString)
        return cached
    }
}
