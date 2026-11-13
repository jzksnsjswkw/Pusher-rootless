import Foundation

/// Asks `imagent` which number a message was received on, then names the SIM.
///
/// Two facts, from two places, because neither holds both:
///
/// - The receiving number is on the message row as `destination_caller_id`, and
///   only `imagent` may open that database.
/// - Which slot that number belongs to is in the settings (see
///   ``ActiveSIMController``), which is also where the name comes from. Matching on
///   the number rather than on a slot column is not a shortcut: the database has no
///   slot column at all.
///
/// Everything is `nil`-on-failure rather than an error: this decorates a push that
/// is already going out, so a miss means less detail, not a lost notification.
public enum SMSLookup {
    /// Why the last lookup returned nothing, for the log page.
    ///
    /// `PusherLog.debug` is compiled out of release builds, so a failure recorded
    /// only there is a failure nobody can see. This carries the reason to the one
    /// place a user can read it.
    public private(set) static var lastFailure: String?

    /// The SIM a notification arrived on.
    ///
    /// `guid` is `context[CKBBContextKeyMessageGUID]` — the same value the
    /// notification carries as `publisherBulletinID`, and the row key in the SMS
    /// database.
    public static func subscription(guid: String) -> SIMSubscription? {
        lastFailure = nil
        guard !guid.isEmpty else {
            lastFailure = "the notification carried no message id"
            return nil
        }

        // Over XPC, and answered directly rather than written somewhere to be
        // polled for.
        //
        // `CPDistributedMessagingCenter` was the first attempt and its handler was
        // never invoked in `imagent` — the sandbox refuses the lookup. SandyXpc
        // reaches the same mach service through `bootstrap_look_up`, which the
        // daemon may do, and the reply comes back on the call.
        guard let reply = SMSXPC.lookup(guid: guid) else {
            lastFailure = "imagent is not reachable"
            PusherLog.info("[PusherSMS] lookup failed: \(lastFailure ?? "")")
            return nil
        }

        // The database records the receiving number and nothing else — there is no
        // slot column — so the number is what identifies the card, and CoreTelephony
        // is what turns it into a slot.
        PusherLog.info("[PusherSMS] lookup reply: \(reply)")
        guard (reply["found"] as? NSNumber)?.boolValue == true,
              let number = reply["phoneNumber"] as? String,
              !number.isEmpty
        else {
            lastFailure = "no message row with that id"
            return nil
        }
        // Matched against the SIMs CoreTelephony reports, not against the settings
        // page: the settings page is free text, so a hand-edited number there must
        // not be able to make the match fail.
        guard let detected = SIMSubscriptions.subscription(forPhoneNumber: number) else {
            lastFailure = "received on \(number), which is not a current SIM"
            return nil
        }
        // The slot is the truth; name comes from the settings page so the user's
        // own wording is what appears in the push.
        return displaySubscription(slot: detected.slot, fallback: detected)
    }

    /// What the push reports: the detected slot, described with the user's words.
    ///
    /// A slot with nothing configured falls back to what CoreTelephony said, so the
    /// line is never blank just because the settings page was not filled in.
    private static func displaySubscription(
        slot: Int, fallback: SIMSubscription
    ) -> SIMSubscription {
        let global = PrefsStore.global()
        let name = global.string(PrefKey.simNameKey(slot: slot)) ?? ""
        return SIMSubscription(
            slot: slot,
            phoneNumber: fallback.phoneNumber,
            label: name.isEmpty ? fallback.label : name
        )
    }
}
