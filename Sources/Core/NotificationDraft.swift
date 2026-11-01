import Foundation
import UIKit

/// A notification described by the user instead of by an app.
///
/// The test push used to be one fixed notification — "Settings: Title / Subtitle /
/// Message". That answers "is my credential right?" and nothing else: it cannot
/// show what a WeChat notification looks like when the title is the sender, or
/// what an SMS payload carries once a SIM slot is involved. A draft is the same
/// bulletin built from fields the user fills in, so a test push can exercise the
/// cases the fixed one cannot.
///
/// Shared rather than test-only on purpose. The script editor runs a script
/// against a sample notification, and until now that sample was another constant;
/// a draft is what both should be written against, so what the user sees in the
/// editor is what the pipeline will build.
public struct NotificationDraft {
    /// The sending app as the pipeline identifies it: a bundle identifier.
    public var appID: String
    /// The sending app's display name, composed into `displayTitle`.
    public var appName: String
    public var title: String
    public var subtitle: String
    public var message: String
    /// A file to attach, or `nil` for a notification with no image.
    public var attachmentURL: URL?
    /// The SIM slot the notification "arrived on", for Messages only.
    ///
    /// Only ever set for `com.apple.MobileSMS`: no other app has a slot, and a
    /// `sim` field on a WeChat notification would be a lie a script could read.
    public var sim: SIMSubscription?

    /// The hook a Run already executed in its editor, if this draft came from one.
    ///
    /// Carried to the pipeline so it skips that phase: the editor runs the hook to
    /// show what it decided, and running it again on the way to the service would
    /// apply its edits twice — a hook that appends text appended it twice in the
    /// payload that actually went out.
    public var ranHook: BulletinHookRunner.Phase?

    /// The content a test notification starts with.
    ///
    /// One set, here, because every test page opens on it: the instance's test
    /// button, the compose page and a script's Run all start from a notification
    /// that says which one it is.
    public enum TestContent {
        public static let appID = NotificationDraft.messagesAppID
        public static let title = "Title"
        public static let subtitle = "Subtitle"
        public static let message = "Message"
    }

    /// The app a draft defaults to before the user picks one.
    ///
    /// Messages, because an SMS is the notification with the most to it — a card,
    /// a number, and a body that arrives as the title — and therefore the one worth
    /// checking a payload against.
    public static let defaultAppID = NotificationDraft.messagesAppID

    /// The bundle identifier of the Messages app.
    public static let messagesAppID = "com.apple.MobileSMS"

    public init(
        appID: String = TestContent.appID,
        appName: String = NotificationDraft.displayName(
            forBundleID: TestContent.appID
        ),
        title: String = TestContent.title,
        subtitle: String = TestContent.subtitle,
        message: String = TestContent.message,
        attachmentURL: URL? = nil,
        // The card a composed notification starts on, when the app has one. The
        // first slot that is actually installed, so a two-SIM phone opens on the
        // card a message would most likely arrive on rather than on slot 1 by
        // default.
        sim: SIMSubscription? = TestContent.appID == NotificationDraft.messagesAppID
            ? NotificationDraft.defaultSIM()
            : nil
    ) {
        self.appID = appID
        self.appName = appName
        self.title = title
        self.subtitle = subtitle
        self.message = message
        self.attachmentURL = attachmentURL
        self.sim = sim
    }

    /// The display name a draft shows for an app it was given the identifier of.
    ///
    /// Goes through the same lookup the pipeline uses, so the name in the form and
    /// the name in `displayTitle` are one string rather than two that agree by
    /// accident.
    public static func displayName(forBundleID appID: String) -> String {
        // Two processes need this: SpringBoard, where `SBApplicationController`
        // knows every app, and Preferences, which has no SpringBoard at all. Going
        // through LaunchServices answers in both — it is the same database the app
        // picker on this page reads, so the name in the form and the name beside
        // the icon cannot disagree.
        if let proxy = lsApplicationProxy(appID),
           let name = Runtime.send(proxy, "localizedName") as? String,
           !name.isEmpty {
            return name
        }
        return BulletinAdapter.appName(forBundleID: appID)
    }

    private static func lsApplicationProxy(_ appID: String) -> AnyObject? {
        guard let cls = Runtime.cls("LSApplicationProxy") else { return nil }
        return Runtime.classSend(cls, "applicationProxyForIdentifier:", appID as NSString)
    }

    /// The name of the app a draft starts on.
    public static func defaultAppName() -> String {
        displayName(forBundleID: defaultAppID)
    }

    /// The card a new draft starts on.
    ///
    /// The first slot that actually holds a SIM — slot 1 when there is one, slot 2
    /// otherwise — so the page opens on a card the message could really have
    /// arrived on. `nil` when neither slot has one, which leaves the field on
    /// "none" rather than claiming a card that is not there.
    public static func defaultSIM() -> SIMSubscription? {
        let subscriptions = SIMSubscriptions.all()
        return subscriptions.first { $0.slot == 1 } ?? subscriptions.first { $0.slot == 2 }
    }

    /// A path in a directory both Preferences and SpringBoard can open.
    ///
    /// The attachment crosses the process boundary as a path, so it has to live
    /// somewhere both processes may read. Each side's own `temporaryDirectory` is
    /// inside its sandbox container and invisible to the other; the shared
    /// preferences directory is not, and it is already where this tweak keeps the
    /// files the two sides hand over.
    public static func attachmentScratchURL() -> URL? {
        guard let directory = NSSearchPathForDirectoriesInDomains(
            .libraryDirectory, .userDomainMask, true
        ).first.map({ URL(fileURLWithPath: $0).appendingPathComponent("Preferences") })
        else { return nil }
        // A fresh name per pick, so two drafts open at once cannot overwrite each
        // other's image while both are on screen.
        return directory.appendingPathComponent("pusher-draft-\(UUID().uuidString).png")
    }

    /// Whether this app can carry a SIM slot.
    public var canHaveSIM: Bool { appID == Self.messagesAppID }

    /// The draft with the SIM field cleared for an app that cannot carry one.
    public func normalised() -> NotificationDraft {
        var copy = self
        if !copy.canHaveSIM { copy.sim = nil }
        return copy
    }

    /// The bulletin and context this draft describes.
    ///
    /// Building both here keeps the two of them consistent: the bulletin is what a
    /// reader of `BBBulletin` would see, and the context is what every service and
    /// script actually consumes. Splitting the construction across two call sites
    /// is how the display strings and the raw fields drift apart.
    ///
    /// - Parameter isTest: marks the context as a test, which is what makes the
    ///   app, notification-settings and device filters skip it. A custom test
    ///   notification still asks "does my *credential* work"; the rules that
    ///   suppress unwanted pushes are not meant to interfere with answering that.
    public func makeContext(test: TestOrigin? = nil) -> BulletinContext {
        let draft = normalised()
        // A draft from a hook's Run carries the phase its editor already executed.
        // That is what tells the pipeline to skip it — the same `hasRun` check the
        // editor sets when it builds the sample context, except this one survives
        // the trip through the messaging centre.
        let resolvedTest = test ?? draft.ranHook.map { TestOrigin.hook($0) } ?? .composed

        let bulletin = BBBulletin()
        bulletin.title = draft.title
        bulletin.subtitle = draft.subtitle.isEmpty ? nil : draft.subtitle
        bulletin.message = draft.message
        bulletin.date = Date()
        bulletin.sectionID = draft.appID
        // A fresh identifier per build, so two test pushes are two log sections
        // rather than one that keeps growing.
        let identifier = UUID().uuidString
        bulletin.publisherBulletinID = identifier

        if let url = draft.attachmentURL,
           let attachment = BulletinAttachment.make(url: url, identifier: "DraftImage") {
            bulletin.primaryAttachment = attachment
        }

        var context = BulletinAdapter.context(
            for: bulletin,
            test: resolvedTest,
            appName: draft.appName,
            displayTitle: BulletinAdapter.displayTitle(
                appName: draft.appName, title: draft.title
            ),
            displayMessage: BulletinAdapter.displayMessage(
                subtitle: draft.subtitle,
                message: draft.message,
                // Asked for explicitly: `showsSubtitle` is readonly on a bulletin
                // built this way and is never set, so leaving it to the bulletin
                // silently dropped the subtitle from every test push.
                showsSubtitle: !draft.subtitle.isEmpty
            ),
            // The notification settings come from `BBServer`, which is a
            // SpringBoard object. In the tweak the adapter reads them directly;
            // in Preferences there is no server, and a lookup here would return a
            // context the pipeline cannot use. The caller fills them in — see
            // `PushEngine.send`.
            skipsSectionLookup: !BulletinAdapter.hasServer
        )

        // Assigned after the adapter runs: the adapter resolves an SMS slot by
        // querying `imagent` with this bulletin's identifier, and a draft has no
        // database row behind it. Skipping that lookup also keeps a test push off
        // the cross-process path entirely.
        context.simSubscription = draft.sim
        return context
    }

    /// What the script editor shows a run: the same notification, as the
    /// dictionary a script reads as `bullet`.
    ///
    /// Built through a context rather than written out by hand so a draft's field
    /// names cannot drift from a real notification's.
}
