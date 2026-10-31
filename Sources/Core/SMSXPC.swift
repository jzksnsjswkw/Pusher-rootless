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
            NSLog("[PusherSMS] client: SandyXpcMessagingCenter unavailable")
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
        // The call itself runs off the caller's thread. The blocked thread cannot
        // be reclaimed if the daemon never answers — `send` holds it until the
        // connection is invalidated — so it is a `qos: .utility` thread that leaks
        // in that case, which is the price of not freezing SpringBoard.
        let done = DispatchSemaphore(value: 0)
        var box: [String: Any]?
        DispatchQueue.global(qos: .utility).async {
            let reply = send(
                center, selector, messageName as NSString,
                ["guid": guid] as NSDictionary, &error
            )
            box = reply as? [String: Any]
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            NSLog("[PusherSMS] client: timeout after \(timeout)s")
            return nil
        }
        NSLog("[PusherSMS] client: reply \(box.map { "\($0)" } ?? "nil, error \(String(describing: error))")")
        return box
    }



    /// The client side, made once.
    ///
    /// `centerNamed:` builds a connection lazily, and reusing it keeps repeated
    /// lookups from paying for a new mach port each time.
    private static var cached: AnyObject?

    private static func makeCenter() -> AnyObject? {
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
