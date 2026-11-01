import Foundation
import UIKit

/// Builds the synthetic bulletin a test push sends.
///
/// A test push has no real app behind it, so the bulletin's display strings and
/// "app name" are supplied here instead of being derived from SpringBoard. The
/// resulting context is marked `isTest`, which is what makes the per-app filters
/// (app list, notification settings, device conditions) skip it: the user
/// explicitly asked for this push, so the rules that suppress *unwanted* pushes
/// do not apply.
///
/// Exposed to ObjC so the distributed-messaging hook can call it; see
/// `Sources/Hooks/TestPush.xm`.
@objc(NSPTestPush)
public final class TestPush: NSObject {
    /// Result of a test push, as far as it can be known before the network
    /// answers.
    ///
    /// The transport is asynchronous: `send` returns once the request is queued,
    /// and the server's answer arrives seconds later on another queue. Reporting
    /// "Sent" at that point was a claim nothing had verified — a missing
    /// credential, an unknown mail domain or a rejected token all failed after
    /// the banner had already said success. What can be reported synchronously is
    /// whether a request was built at all, and the caller says that instead.
    public struct Result {
        /// The instance exists in the current configuration.
        public let hasInstance: Bool
        /// A request came out of the service, `nil` when building is still running.
        public let builtRequest: Bool?
        /// Why not, when no request could be built.
        public let failureReason: String?
    }

    /// The IPC reply. A dictionary, because the answer has three cases and one of
    /// them is not a failure: `built` distinguishes "the fields are wrong" from
    /// "the request is on its way".
    /// The IPC reply for a test push.
    ///
    /// `draft` is the JSON of a ``NotificationDraft``: present when the user built
    /// their own notification, absent for the fixed one. It is passed as JSON
    /// rather than as a dictionary because every field then arrives as the type it
    /// was written as, and an unknown key fails here instead of silently sending a
    /// notification with a default title.
    @objc(sendTestPushToService:draftJSON:)
    public static func sendTestPush(toService service: String,
                                    draftJSON: String?) -> [String: Any] {
        let draft = draftJSON.flatMap { decodeDraft($0) }
        let result = send(toInstanceID: service, draft: draft)
        var reply: [String: Any] = ["hasInstance": result.hasInstance]
        if let built = result.builtRequest { reply["builtRequest"] = built }
        if let reason = result.failureReason { reply["reason"] = reason }
        return reply
    }

    public static func send(toInstanceID service: String,
                            draft: NotificationDraft? = nil) -> Result {
        guard !service.isEmpty, BulletinAdapter.shared.server != nil else {
            return Result(hasInstance: false, builtRequest: nil, failureReason: nil)
        }

        // One context builder for every test: the fixed push, a composed one and a
        // hook Run differ only in what they put in the draft, never in how the
        // context is marked.
        let context = (draft ?? defaultDraft()).makeContext()

        guard PushEngine.shared.hasInstance(id: service) else {
            return Result(hasInstance: false, builtRequest: nil, failureReason: nil)
        }

        // Build once, synchronously enough to answer the IPC call: the caller is
        // waiting for a verdict and a build is a pure function of the config (the
        // one exception, WeChat's token fetch, is the case this is meant to catch).
        var built: Bool?
        var reason: String?
        let done = DispatchSemaphore(value: 0)
        PushEngine.shared.buildTestRequest(id: service, context: context) { result in
            switch result {
            case .success:
                built = true
            case .failure(let error):
                built = false
                reason = error.localizedDescription
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)

        guard built == true else {
            return Result(hasInstance: true, builtRequest: built, failureReason: reason)
        }

        PushEngine.shared.send(to: service, context: context)
        return Result(hasInstance: true, builtRequest: true, failureReason: nil)
    }

    /// The notification a plain "Send Test Notification" sends.
    ///
    /// Fixed, recognizable content: a test asks whether the credential works, and
    /// an obviously synthetic notification makes it clear which push answered.
    private static func defaultDraft() -> NotificationDraft {
        // No attachment. A test asks whether the credential works, and an image
        // that every push carries is an image the user has to strip from every
        // service that does not want one. Pages that want to try an attachment
        // pick one.
        NotificationDraft()
    }

    /// Reads a draft from the IPC payload.
    ///
    /// A dictionary of primitives rather than a decoded class: this crosses a
    /// process boundary through `CPDistributedMessagingCenter`, where only
    /// property-list types survive, and an archived object would arrive as data
    /// the other side cannot name.
    /// The draft a `display` request carries, as fields the O
    /// bridge can hand over one by one.
    @objc(draftFields:)
    public static func draftFields(_ json: String?) -> [String: Any]? {
        guard let json, let draft = decodeDraft(json) else { return nil }
        var fields: [String: Any] = [
            "appID": draft.appID,
            "title": draft.title,
            "subtitle": draft.subtitle,
            "message": draft.message,
        ]
        if let url = draft.attachmentURL { fields["attachmentPath"] = url.path }
        if let sim = draft.sim {
            fields["simSlot"] = sim.slot
            fields["simPhone"] = sim.phoneNumber
            fields["simLabel"] = sim.label
        }
        // `rawValue`, not the enum. This dictionary goes straight into an
        // Objective-C reply, and a Swift enum is not an object there: it arrives as
        // an opaque value that `_copyDescription` cannot describe, and passing it
        // to a `NSString *` parameter aborts the process.
        if let phase = draft.ranHook { fields["ranHook"] = phase.rawValue }
        return fields
    }

    static func decodeDraft(_ json: String) -> NotificationDraft? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any]
        else { return nil }

        var draft = NotificationDraft()
        if let appID = fields["appID"] as? String, !appID.isEmpty { draft.appID = appID }
        if let appName = fields["appName"] as? String { draft.appName = appName }
        draft.title = fields["title"] as? String ?? ""
        draft.subtitle = fields["subtitle"] as? String ?? ""
        draft.message = fields["message"] as? String ?? ""
        if let path = fields["attachmentPath"] as? String, !path.isEmpty {
            draft.attachmentURL = URL(fileURLWithPath: path)
        }
        // The hook a Run already executed in its editor. Carried through the IPC
        // hop so the pipeline skips it — running it again would apply its edits a
        // second time, which shows up as a hook that doubles whatever it appends.
        if let ran = fields["ranHook"] as? String {
            draft.ranHook = BulletinHookRunner.Phase(rawValue: ran)
        }
        if let sim = fields["sim"] as? [String: Any] {
            draft.sim = SIMSubscription(
                slot: sim["slot"] as? Int ?? 0,
                phoneNumber: sim["phoneNumber"] as? String ?? "",
                label: sim["label"] as? String ?? ""
            )
        }
        return draft.normalised()
    }

    /// The image that appears in the test notification: the tweak's own icon,
    /// resolved from the installed Preferences bundle.
}
