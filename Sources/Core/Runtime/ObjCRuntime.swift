import Foundation
import ObjectiveC

/// Calls into classes that must **not** be linked.
///
/// The tweak injects into both SpringBoard and Preferences.app, and
/// `SpringBoard.framework` is not present in the latter. Referring to a
/// SpringBoard class by name from Swift (even through a bridging header) emits
/// a hard `_OBJC_CLASS_$_X` reference, so the dynamic linker would refuse to
/// load the tweak into Preferences. Every SpringBoard access therefore goes
/// through the runtime — the same thing `NSClassFromString` does in the ObjC
/// version of this code.
///
/// Return values are `AnyObject?`; callers cast with `as?`, which is safe
/// because the cast only succeeds when the object really is that type (for
/// instance an `@objc` protocol the dynamic class happens to implement).
public enum Runtime {

    // MARK: - Classes

    /// The class object for a runtime name, or `nil` when it is not loaded.
    public static func cls(_ name: String) -> AnyClass? {
        NSClassFromString(name) as AnyClass?
    }

    /// Whether a class is currently loaded.
    public static func hasClass(_ name: String) -> Bool {
        cls(name) != nil
    }

    // MARK: - Messaging

    /// `[receiver selector]`
    public static func send(_ receiver: AnyObject?, _ selector: String) -> AnyObject? {
        guard let receiver, let imp = implementation(of: receiver, selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> AnyObject?
        return unsafeBitCast(imp, to: Fn.self)(receiver, NSSelectorFromString(selector))
    }

    /// `[receiver selector:arg]`
    public static func send(_ receiver: AnyObject?, _ selector: String, _ arg: AnyObject?) -> AnyObject? {
        guard let receiver, let imp = implementation(of: receiver, selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
        return unsafeBitCast(imp, to: Fn.self)(receiver, NSSelectorFromString(selector), arg)
    }

    /// `[receiver selector:arg1 :arg2]`
    public static func send(_ receiver: AnyObject?, _ selector: String,
                            _ arg1: AnyObject?, _ arg2: AnyObject?) -> AnyObject? {
        guard let receiver, let imp = implementation(of: receiver, selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> AnyObject?
        return unsafeBitCast(imp, to: Fn.self)(receiver, NSSelectorFromString(selector), arg1, arg2)
    }

    /// `[receiver selector]` where the return value is a scalar `Bool`.
    public static func sendBool(_ receiver: AnyObject?, _ selector: String) -> Bool {
        guard let receiver, let imp = implementation(of: receiver, selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(imp, to: Fn.self)(receiver, NSSelectorFromString(selector))
    }

    /// `[receiver selector]` where the return value is an integer.
    public static func sendInt(_ receiver: AnyObject?, _ selector: String) -> Int {
        guard let receiver, let imp = implementation(of: receiver, selector) else { return 0 }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Int
        return unsafeBitCast(imp, to: Fn.self)(receiver, NSSelectorFromString(selector))
    }

    // MARK: - Class methods

    /// `[Class selector]` for a runtime-resolved class.
    ///
    /// A class object is an instance of its *metaclass*, so a class method is
    /// looked up as an instance method on `object_getClass(cls)`. A protocol
    /// cast cannot express this (a `static func` requirement is not satisfied
    /// by a class object), which is why this uses an IMP thunk instead.
    public static func classSend(_ cls: AnyClass?, _ selector: String) -> AnyObject? {
        guard let cls,
              let metaclass = object_getClass(cls),
              let method = class_getInstanceMethod(metaclass, NSSelectorFromString(selector))
        else { return nil }
        typealias Fn = @convention(c) (AnyClass, Selector) -> AnyObject?
        let imp = method_getImplementation(method)
        return unsafeBitCast(imp, to: Fn.self)(cls, NSSelectorFromString(selector))
    }

    /// `[[Class sharedInstance] selector]` — the common private-framework
    /// singleton lookup, returning `nil` when either step is unavailable.
    public static func sharedInstance(_ className: String) -> AnyObject? {
        classSend(cls(className), "sharedInstance")
    }

    private static func implementation(of receiver: AnyObject, _ selector: String) -> IMP? {
        guard let method = class_getInstanceMethod(object_getClass(receiver),
                                                   NSSelectorFromString(selector)) else { return nil }
        return method_getImplementation(method)
    }

    // MARK: - Instance variables

    /// Reads an ObjC ivar.
    ///
    /// Swift does not import ObjC ivars, so the `@public` `SEL setter` /
    /// `SEL getter` slots on `PSSpecifier` have to go through the runtime.
    public static func getIvar<T>(_ object: AnyObject, _ name: String, as type: T.Type) -> T? {
        guard let ivar = class_getInstanceVariable(object_getClass(object), name),
              let raw = object_getIvar(object, ivar)
        else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }

    /// Writes an ObjC ivar. The value must be an object (a `Selector`, for
    /// instance, is a pointer and bridges to `AnyObject`).
    @discardableResult
    public static func setIvar(_ object: AnyObject, _ name: String, _ value: AnyObject?) -> Bool {
        guard let ivar = class_getInstanceVariable(object_getClass(object), name) else { return false }
        object_setIvar(object, ivar, value)
        return true
    }

    /// Reads an ivar of a scalar (non-object) type.
    ///
    /// `object_getIvar` only handles object types, so a `BOOL` or integer ivar
    /// has to be read from the instance's storage directly. Used for the
    /// `@protected` state inside third-party controllers
    /// (`ATLApplicationListMultiSelectionController`'s selection set and default
    /// switch value), which Swift cannot see and which no accessor exposes.
    public static func getScalarIvar<T>(_ object: AnyObject, _ name: String, as type: T.Type) -> T? {
        guard let ivar = class_getInstanceVariable(object_getClass(object), name)
        else { return nil }
        let pointer = Unmanaged.passUnretained(object).toOpaque()
            .advanced(by: ivar_getOffset(ivar))
            .assumingMemoryBound(to: T.self)
        return pointer.pointee
    }

    /// Writes an ivar of a scalar type. See ``getScalarIvar(_:_:as:)``.
    @discardableResult
    public static func setScalarIvar<T>(_ object: AnyObject, _ name: String, _ value: T) -> Bool {
        guard let ivar = class_getInstanceVariable(object_getClass(object), name) else { return false }
        let pointer = Unmanaged.passUnretained(object).toOpaque()
            .advanced(by: ivar_getOffset(ivar))
            .assumingMemoryBound(to: T.self)
        pointer.pointee = value
        return true
    }
}

// MARK: - Method hooking

/// Replaces method implementations and calls the originals back.
///
/// This is the plain-runtime equivalent of the Logos `%hook` / `%orig` the ObjC
/// version of the tweak used. Logos is not available to Swift, and Orion's
/// `ClassHook` DSL is not used by this project, so hooks are installed here and
/// the original implementation is reached through ``orig(_:_:_:)``.
public enum Hook {
    private static var originals: [String: IMP] = [:]
    private static let lock = NSLock()

    /// Installs `body` as the implementation of `selector` on `cls`, keeping
    /// the previous implementation reachable through ``orig(_:_:_:)``.
    ///
    /// The body is called with the receiver and the second argument (the first
    /// is always the selector); callers that need more arguments use the
    /// ``install(className:_:argCount:body:)`` variant.
    @discardableResult
    public static func install(
        _ className: String,
        _ selector: String,
        body: @escaping (AnyObject, AnyObject?) -> Void
    ) -> Bool {
        install(className, selector, instance: true) { receiver, _, arg in
            body(receiver, arg)
            return nil
        }
    }

    /// Installs a hook whose body takes no arguments beyond the receiver.
    @discardableResult
    public static func installVoid(
        _ className: String,
        _ selector: String,
        body: @escaping (AnyObject) -> Void
    ) -> Bool {
        install(className, selector, instance: true) { receiver, _, _ in
            body(receiver)
            return nil
        }
    }

    /// The shared installer. `body` receives `(receiver, selector, firstArgument)`
    /// and its return value becomes the method's.
    @discardableResult
    public static func install(
        _ className: String,
        _ selector: String,
        instance: Bool = true,
        body: @escaping (AnyObject, Selector, AnyObject?) -> AnyObject?
    ) -> Bool {
        guard let cls = Runtime.cls(className) else { return false }
        let target: AnyClass = instance ? cls : (object_getClass(cls) ?? cls)
        let sel = NSSelectorFromString(selector)
        guard let method = class_getInstanceMethod(target, sel) else { return false }

        let key = storageKey(className, selector, instance)
        lock.lock()
        if originals[key] == nil {
            originals[key] = method_getImplementation(method)
        }
        lock.unlock()

        let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { receiver, arg in
            body(receiver, sel, arg)
        }
        let imp = imp_implementationWithBlock(block)
        let previous = class_replaceMethod(target, sel, imp, method_getTypeEncoding(method))
        // A nil previous IMP means the method did not exist on this class, so
        // hooking it would only add a method rather than replace one.
        return previous != nil
    }

    /// Calls the original implementation of a hooked selector.
    ///
    /// Pass the same selector string that was installed; the receiver's own
    /// class is used to resolve the stored IMP, so an inherited hook still
    /// finds the right one.
    public static func orig(_ receiver: AnyObject?, _ selector: String, _ arg: AnyObject? = nil) -> AnyObject? {
        guard let receiver else { return nil }
        let classNames = candidateClassNames(for: receiver)
        lock.lock()
        let imp = classNames.compactMap { originals[storageKey($0, selector, true)] }.first
        lock.unlock()
        guard let imp else { return nil }

        typealias Fn1 = @convention(c) (AnyObject, Selector) -> AnyObject?
        typealias Fn2 = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
        let sel = NSSelectorFromString(selector)
        if arg == nil {
            return unsafeBitCast(imp, to: Fn1.self)(receiver, sel)
        }
        return unsafeBitCast(imp, to: Fn2.self)(receiver, sel, arg)
    }

    /// The receiver's class and its superclasses, so a hook installed on a
    /// superclass is still found for a subclass instance.
    private static func candidateClassNames(for receiver: AnyObject) -> [String] {
        var names: [String] = []
        var cls: AnyClass? = object_getClass(receiver)
        while let current = cls {
            names.append(NSStringFromClass(current))
            cls = class_getSuperclass(current)
        }
        return names
    }

    private static func storageKey(_ className: String, _ selector: String, _ instance: Bool) -> String {
        "\(instance ? "i" : "c"):\(className).\(selector)"
    }
}
