import Foundation
import SystemConfiguration

/// Answers "is this device currently on Wi-Fi?".
///
/// This replaces a SpringBoard private API the original used:
/// `SBWiFiManager.currentNetworkName` existed on older iOS, but the class is gone
/// on iOS 16 — `NSClassFromString` returns nil, `currentNetworkName` was
/// therefore always nil, and "Wi-Fi Only" could never match. The tweak silently
/// treated every connection as cellular.
///
/// The replacement asks the system directly, which is both version-stable and
/// more accurate than a SpringBoard property:
///
/// - `SystemConfiguration`'s reachability reports whether a route exists, and
///   marks it as cellular (`IsWWAN`) when it goes over the cellular interface.
///   Reachable without `IsWWAN` means Wi-Fi (or another non-cellular link).
/// - The `en0` interface carries the Wi-Fi interface's address on iPhone, so a
///   routable IPv4 address on it confirms an association. This is only consulted
///   when reachability says the device is offline, since a captive portal can be
///   associated-but-unreachable.
public enum NetworkReachability {

    /// The device's current network, as a script sees it.
    ///
    /// One query answers all three of "offline", "on Wi-Fi" and "on cellular",
    /// so the two consumers — the "What Network" filter and a hook's `device`
    /// object — cannot disagree about what the device is doing.
    public static func current() -> DeviceState.Network {
        if let flags = internetReachabilityFlags() {
            guard flags.contains(.reachable) else {
                // Associated but not routable (a captive portal) still counts as
                // a Wi-Fi connection for a hook's purposes, matching the filter's
                // fallback below.
                return hasWiFiAddress() ? .wifi : .none
            }
            return flags.contains(.isWWAN) ? .cellular : .wifi
        }
        return hasWiFiAddress() ? .wifi : .none
    }

    /// Whether the device currently has a non-cellular network connection.
    ///
    /// Returns `false` when the device is offline, and `false` when the only
    /// usable route is cellular — which is what makes "Wi-Fi Only" and
    /// "Cellular Only" distinguishable without a SpringBoard dependency.
    public static func isOnWiFi() -> Bool {
        current() == .wifi
    }

    /// The reachability flags for the general internet, or `nil` when the
    /// registrar cannot be created or queried.
    private static func internetReachabilityFlags() -> SCNetworkReachabilityFlags? {
        var zero = sockaddr_in()
        zero.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zero.sin_family = sa_family_t(AF_INET)

        // A zero address asks about general internet reachability rather than
        // about one specific host. The returned object is ARC-managed, so there
        // is no `CFRelease` here.
        guard let reachability = withUnsafePointer(to: &zero, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                SCNetworkReachabilityCreateWithAddress(nil, address)
            }
        }) else { return nil }

        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reachability, &flags) else { return nil }
        return flags
    }

    /// Whether `en0` (the Wi-Fi interface on iPhone) holds a routable IPv4
    /// address, which means the device is associated with a network.
    private static func hasWiFiAddress() -> Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return false }
        defer { freeifaddrs(addresses) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let name = interface.ifa_name, String(cString: name) == "en0",
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            // An address of 0.0.0.0 means the interface exists but has not been
            // configured, so it does not count as a connection.
            let value = withUnsafePointer(to: address.pointee) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
            }
            if value != 0 { return true }
        }
        return false
    }
}
