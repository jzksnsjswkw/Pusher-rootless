import Foundation

/// Debug logging for the Pusher pipeline.
///
/// `NSLog` goes to the system log, which the tweak can only reach from inside
/// SpringBoard; prefixing every line with the file and line makes a log excerpt
/// traceable back to the call site without a debugger attached.
public enum PusherLog {
    public static func debug(_ message: @autoclosure () -> String,
                             file: String = #fileID,
                             line: Int = #line) {
        #if DEBUG
        NSLog("[\(Pusher.name):\(file):\(line)] \(message())")
        #else
        _ = message
        #endif
    }

    /// Logs unconditionally, including in release builds. Used for the few
    /// messages that should always reach the system log.
    public static func info(_ message: @autoclosure () -> String,
                            file: String = #fileID,
                            line: Int = #line) {
        NSLog("[\(Pusher.name):\(file):\(line)] \(message())")
    }
}

/// The same unconditional log, reachable from the ObjC shortcut runner.
///
/// `PusherLog` is a Swift enum, so its members have no ObjC name; the runner
/// needs one to report a shortcut that could not be started.
@_cdecl("PusherLogError")
public func PusherLogError(_ message: UnsafePointer<CChar>) {
    PusherLog.info(String(cString: message))
}

/// Formats a value for the on-device log viewer.
///
/// Dictionaries and arrays are expanded with indentation so a nested request
/// body stays readable in the log; long strings are truncated unless the
/// caller asks otherwise (error descriptions, for example, should survive
/// whole).
public enum LogString {
    public static func describe(_ object: Any?, dontTruncate: Bool = false) -> String {
        format(object, prefix: "", dontTruncate: dontTruncate)
    }

    private static func format(_ object: Any?, prefix: String, dontTruncate: Bool) -> String {
        guard let object else { return "\(prefix)nil" }

        if let array = object as? [Any] {
            var out = "["
            for value in array {
                out += "\n\(prefix)\t"
                    + format(value, prefix: "\(prefix)\t", dontTruncate: dontTruncate)
            }
            return out + "\n\(prefix)]"
        }

        if let dict = object as? [String: Any] {
            var out = "{"
            for key in dict.keys.sorted() {
                out += "\n\(prefix)\t\(key): "
                    + format(dict[key], prefix: "\(prefix)\t", dontTruncate: dontTruncate)
            }
            return out + "\n\(prefix)}"
        }

        if !dontTruncate, let string = object as? String, string.count > Pusher.logMaxStringLength {
            return prefix + String(string.prefix(Pusher.logMaxStringLength)) + "..."
        }

        return prefix + String(describing: object)
    }
}
