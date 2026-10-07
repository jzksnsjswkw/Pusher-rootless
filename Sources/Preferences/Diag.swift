import Foundation

/// TEMPORARY diagnostic.
enum Diag {
    static func note(_ message: String) {
        var existing = CFPreferencesCopyAppValue("trace" as CFString, "com.watermelonpig.diag" as CFString) as? [String] ?? []
        existing.append(message)
        CFPreferencesSetAppValue("trace" as CFString, existing as CFArray, "com.watermelonpig.diag" as CFString)
        CFPreferencesAppSynchronize("com.watermelonpig.diag" as CFString)
    }
}
