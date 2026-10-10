import Foundation
import UIKit

// MARK: - Building against the old SDK
//
// The rootful scheme compiles against the 14.5 SDK, which predates several iOS
// 15 additions the rest of the code names directly. Everything the rest of the
// code needs is declared here, behind `LEGACY_SDK` — one flag from the Makefile
// — so no other file carries a scheme-specific `#if`.
//
// These are compile-time shims only. On an iOS 15+ system the real definitions
// win because this file is not compiled at all; on 14 the shims are what the
// binary contains, and each one notes how close the fallback is.

#if LEGACY_SDK

// `Sendable` and Swift concurrency arrived with iOS 15, and the 14.5 SDK has
// no `_Concurrency` module to import. The pipeline does not use Swift
// concurrency — every thread hop is GCD — so an empty protocol keeps the
// `@unchecked Sendable` annotations meaningful to readers without pulling in
// anything the SDK lacks.
protocol Sendable {}

extension UIColor {
    // Four of the fifteen system colors are iOS 15 additions and are absent
    // from the 14.5 SDK, so they cannot even be referenced by name here — each
    // is rebuilt from its RGB, matching what iOS 15 renders closely enough
    // that a tint row keeps its color family.
    static var systemMint: UIColor { UIColor(red: 0.00, green: 0.78, blue: 0.66, alpha: 1) }
    static var systemTeal: UIColor { UIColor(red: 0.13, green: 0.63, blue: 0.71, alpha: 1) }
    static var systemIndigo: UIColor { UIColor(red: 0.35, green: 0.34, blue: 0.84, alpha: 1) }
    static var systemBrown: UIColor { UIColor(red: 0.65, green: 0.45, blue: 0.26, alpha: 1) }
}

#endif
