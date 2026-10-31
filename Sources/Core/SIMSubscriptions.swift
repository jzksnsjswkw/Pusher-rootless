import Foundation

/// The SIM one phone number belongs to.
public struct SIMSubscription {
    /// `1` or `2`, as CoreTelephony counts slots.
    public let slot: Int
    /// The number the SIM is reached on.
    public let phoneNumber: String
    /// The name the user gave this SIM in Settings — 「旺财」, 「工作号」, or empty.
    public let label: String

    /// What a log line reads, e.g. `slot 2 (旺仔) +8617770856141`.
    /// `slot 2 (旺仔) +8617770856141`, or `slot 2 +8617770856141` when unnamed.
    ///
    /// The label is the user's own word for the card, and the fetch button on the
    /// settings page copies the number into it — so the two are often the same
    /// string. Printing both then reads as a stutter, and the line exists to be
    /// read at a glance in the log.
    public var description: String {
        var parts = ["slot \(slot)"]
        if !label.isEmpty, label != phoneNumber { parts.append("(\(label))") }
        if !phoneNumber.isEmpty { parts.append(phoneNumber) }
        return parts.joined(separator: " ")
    }
}

/// Every SIM the device currently has, read from CoreTelephony.
///
/// This is the whole answer to "which card received this message": the system
/// already knows, and `CoreTelephonyClient` hands it over in one call — slot, user
/// label and phone number for every SIM. An earlier design captured the same data
/// by hooking the message-delivery path inside `imagent` and asking that process
/// later; reading it directly is both simpler and available before any message
/// arrives.
public enum SIMSubscriptions {
    /// The current SIMs, in slot order.
    ///
    /// Read every time rather than cached. The call is one XPC round trip to
    /// CoreTelephony and the answer cannot go stale — a tray swap, a rename in
    /// Settings, a SIM being removed: all of it is picked up immediately, which a
    /// cache would silently get wrong for up to its lifetime.
    public static func all() -> [SIMSubscription] {
        read()
    }

    /// The current SIMs, read again.
    ///
    /// Kept as a separate name because its callers say what they mean — the SIM
    /// page's "get" button is explicitly asking the device — even though there is
    /// no longer a cached path for it to bypass.
    public static func refreshed() -> [SIMSubscription] {
        read()
    }

    /// The SIM currently in a slot, `nil` when that slot is empty.
    public static func subscription(forSlot slot: Int) -> SIMSubscription? {
        all().first { $0.slot == slot }
    }

    /// The SIM a phone number belongs to, `nil` when the number matches none.
    public static func subscription(forPhoneNumber number: String) -> SIMSubscription? {
        guard !number.isEmpty else { return nil }
        return all().first { $0.phoneNumber == number }
    }

    /// Whether CoreTelephony answered at all.
    ///
    /// Separate from ``all()`` because an empty list and a failed read look the
    /// same to a caller that only counts SIMs, and the two mean different things
    /// on a page offering a choice between them.
    public static var isAvailable: Bool {
        Runtime.cls("CoreTelephonyClient") != nil
    }

    /// Reads the list out of CoreTelephony.
    ///
    /// Reached through `Runtime` rather than a direct reference: this runs in the
    /// Preferences bundle too, and naming a private framework class from Swift
    /// emits a hard class reference that bundle cannot resolve. The three
    /// selectors are the whole protocol this needs.
    private static func read() -> [SIMSubscription] {
        guard let clientClass = Runtime.cls("CoreTelephonyClient"),
              let allocated = Runtime.classSend(clientClass, "alloc"),
              let client = Runtime.send(allocated, "init")
        else {
            PusherLog.debug("[SIM] CoreTelephonyClient unavailable")
            return []
        }

        var error: Unmanaged<CFError>?
        guard let info = Runtime.sendWithError(client, "getSubscriptionInfoWithError:",
                                               &error)
        else {
            PusherLog.debug("[SIM] no subscription info")
            return []
        }
        guard let list = Runtime.send(info, "subscriptions") as? NSArray else {
            PusherLog.debug("[SIM] subscription list unreadable")
            return []
        }

        var result: [SIMSubscription] = []
        for index in 0..<list.count {
            guard let context = list.object(at: index) as AnyObject? else { continue }
            let number = Runtime.send(context, "phoneNumber") as? String ?? ""
            guard !number.isEmpty else { continue }
            result.append(SIMSubscription(
                slot: Runtime.sendInt(context, "slotID"),
                phoneNumber: number,
                label: Runtime.send(context, "label") as? String ?? ""
            ))
        }
        return result.sorted { $0.slot < $1.slot }
    }
}
