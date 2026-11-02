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

    /// `[receiver selector:&error]` for a method that takes an `NSError **`.
    ///
    /// The out-parameter is real writable storage: a method that writes through it
    /// crashes the process if handed nil, which is what the plain `send` overload
    /// would pass.
    public static func sendWithError(
        _ receiver: AnyObject?, _ selector: String,
        _ error: UnsafeMutablePointer<Unmanaged<CFError>?>
    ) -> AnyObject? {
        guard let receiver, let imp = implementation(of: receiver, selector) else {
            return nil
        }
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> AnyObject?
        return unsafeBitCast(imp, to: Fn.self)(
            receiver, NSSelectorFromString(selector),
            UnsafeMutableRawPointer(error)
        )
    }

    /// `[receiver selector]` where the return value is a scalar `Bool`.
    public static func sendBool(_ receiver: AnyObject?, _ selector: String) -> Bool {
        guard let receiver, let imp = implementation(of: receiver, selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(imp, to: Fn.self)(receiver, NSSelectorFromString(selector))
    }

    /// `[receiver selector:arg]` where the argument and return value are scalars.
    @discardableResult
    public static func sendBool(_ receiver: AnyObject?, _ selector: String, _ arg: Bool) -> Bool {
        guard let receiver,
              let method = class_getInstanceMethod(object_getClass(receiver), NSSelectorFromString(selector))
        else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Fn.self)(receiver, NSSelectorFromString(selector), arg)
        return true
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

    /// `[Class selector:arg]` for a runtime-resolved class.
    public static func classSend(_ cls: AnyClass?, _ selector: String,
                                 _ arg: AnyObject?) -> AnyObject? {
        guard let cls,
              let metaclass = object_getClass(cls),
              let method = class_getInstanceMethod(metaclass, NSSelectorFromString(selector))
        else { return nil }
        typealias Fn = @convention(c) (AnyClass, Selector, AnyObject?) -> AnyObject?
        let imp = method_getImplementation(method)
        return unsafeBitCast(imp, to: Fn.self)(cls, NSSelectorFromString(selector), arg)
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
    public static func getIvar<T: AnyObject>(_ object: AnyObject, _ name: String, as type: T.Type) -> T? {
        guard let ivar = class_getInstanceVariable(object_getClass(object), name),
              let raw = object_getIvar(object, ivar)
        else { return nil }
        // A checked cast, not a bitcast: an ivar that holds something other
        // than `T` (a different class, or Swift bridging) must read as nil
        // rather than hand back a lying value for the caller to crash on.
        return raw as? T
    }

    /// Writes an ObjC ivar whose declared type is an object.
    ///
    /// The value must be a real object. A `Selector` is *not* one — it is an
    /// opaque pointer — and passing one here would make the caller's ARC retain
    /// it as if it were an object and crash. Use ``setSelectorIvar`` for those.
    @discardableResult
    public static func setIvar(_ object: AnyObject, _ name: String, _ value: AnyObject?) -> Bool {
        guard let ivar = class_getInstanceVariable(object_getClass(object), name) else { return false }
        object_setIvar(object, ivar, value)
        return true
    }

    /// Writes a `SEL` ivar.
    ///
    /// A `Selector` is a pointer to a method name, not an object, so it cannot be
    /// passed through an `AnyObject` parameter: Swift bridges that parameter as
    /// `id` and ARC retains it. Storing the bits directly into the instance's
    /// storage avoids the retain entirely. `object_setIvar` is unusable here for
    /// the same reason.
    @discardableResult
    public static func setSelectorIvar(_ object: AnyObject, _ name: String, _ selector: Selector) -> Bool {
        guard let ivar = class_getInstanceVariable(object_getClass(object), name) else { return false }
        let slot = Unmanaged.passUnretained(object).toOpaque()
            .advanced(by: ivar_getOffset(ivar))
            .assumingMemoryBound(to: Selector?.self)
        slot.pointee = selector
        return true
    }

    /// Reads a `SEL` ivar. See ``setSelectorIvar(_:_:_:)``.
    public static func getSelectorIvar(_ object: AnyObject, _ name: String) -> Selector? {
        guard let ivar = class_getInstanceVariable(object_getClass(object), name) else { return nil }
        let slot = Unmanaged.passUnretained(object).toOpaque()
            .advanced(by: ivar_getOffset(ivar))
            .assumingMemoryBound(to: Selector?.self)
        return slot.pointee
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
//
// There was an `Hook` enum here, a plain-runtime equivalent of Logos' `%hook` and
// `%orig`. Nothing used it: every hook this project installs is written in the
// Objective-C files with Logos, which does it better and without the IMP
// bookkeeping. Removed rather than kept "in case it is needed" — an unused hook
// installer is a second way to do what the code already does, and the next reader
// has no way to tell which one is live.
