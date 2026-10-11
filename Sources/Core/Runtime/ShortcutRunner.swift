import Foundation

/// Runs one of the user's Shortcuts, silently, with the notification as input.
///
/// This is the only service that does not send an HTTP request; what it does
/// instead is described in `ShortcutRunner.m`, which owns the private-API work.
/// This file is the calling side, and it reaches the implementation through
/// `dlsym` rather than by declaring the function.
///
/// Why `dlsym`: the tweak and the Preferences bundle are separate targets. The
/// bundle recompiles the Core sources (a bundle cannot link a static library)
/// and would need the ObjC symbol to link, but it never runs a shortcut. Looking
/// the function up at call time means the bundle compiles and links without it,
/// and a missing tweak shows up as a runtime failure instead of a link error.
enum ShortcutRunner {

    /// Runs `name`, handing it `input` (JSON text).
    ///
    /// Returns `nil` on success, or a description of what went wrong.
    static func run(name: String, input: String) -> String? {
        typealias RunFn = @convention(c) (NSString, NSString) -> NSString?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "PusherRunShortcut") else {
            return "shortcut support is not loaded"
        }
        let run = unsafeBitCast(symbol, to: RunFn.self)
        return run(name as NSString, input as NSString) as String?
    }

    /// Every shortcut name on the device, sorted, for the picker.
    static func names() -> [String] {
        typealias NamesFn = @convention(c) () -> NSArray?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "PusherShortcutNames") else {
            return []
        }
        let names = unsafeBitCast(symbol, to: NamesFn.self)
        return (names() as? [String]) ?? []
    }
}
