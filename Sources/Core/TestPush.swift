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
    /// The notification's fixed content. Sending a recognizable, obviously
    /// synthetic notification makes it clear which push is the test.
    private enum Content {
        static let title = "Title"
        static let subtitle = "Subtitle"
        static let message = "Message"
        /// Shown as the "app" that sent it.
        static let appName = "Settings"
        static let imageName = "icon@3x.png"
        static let identifier = "TestImage"
    }

    /// Sends a test push to one service.
    ///
    /// - Returns: whether the push was handed to the pipeline. `false` means
    ///   SpringBoard is not ready (no `BBServer` yet), which the UI reports as a
    ///   failed send rather than an error.
    @objc(sendTestPushToService:)
    @discardableResult
    public static func send(toService service: String) -> Bool {
        guard !service.isEmpty, BulletinAdapter.shared.server != nil else { return false }

        let bulletin = BBBulletin()
        bulletin.title = Content.title
        bulletin.subtitle = Content.subtitle
        bulletin.message = Content.message
        bulletin.date = Date()
        bulletin.sectionID = testNotificationSectionID

        if let url = testImageURL,
           let attachment = BulletinAttachment.make(url: url, identifier: Content.identifier) {
            bulletin.primaryAttachment = attachment
        }

        let context = BulletinAdapter.context(
            for: bulletin,
            isTest: true,
            appName: Content.appName,
            displayTitle: bulletin.title,
            displayMessage: "\(bulletin.subtitle ?? "")\n\(bulletin.message ?? "")"
        )

        PushEngine.shared.send(to: service, context: context)
        return true
    }

    /// The image that appears in the test notification: the tweak's own icon,
    /// resolved from the installed Preferences bundle.
    private static var testImageURL: URL? {
        guard let bundlePath = Pusher.bundlePath else { return nil }
        return URL(fileURLWithPath: bundlePath).appendingPathComponent(Content.imageName)
    }
}
