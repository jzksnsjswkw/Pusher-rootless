import UIKit
import UserNotifications

/// Shows the result of a test push.
///
/// A local notification is used so the result appears in exactly the place a
/// real push would — that is the point of a test. When the user has not granted
/// notification permission the notification cannot be delivered, so the result
/// falls back to an alert rather than being silently dropped.
public enum TestNotification {
    private static let identifier = "TestNotificationResult"

    /// Presents `message`, preferring a notification and falling back to an
    /// alert.
    ///
    /// - Parameter controller: used to present the fallback alert, and to check
    ///   whether this app is currently frontmost (in which case a banner would
    ///   be hidden behind the alert).
    public static func present(_ message: String, from controller: UIViewController) {
        let content = UNMutableNotificationContent()
        content.title = Pusher.name
        content.body = message

        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil
        )
        let center = UNUserNotificationCenter.current()
        center.add(request) { error in
            guard let error else { return }
            // The completion handler runs on an arbitrary queue; hop back before
            // touching UIKit.
            DispatchQueue.main.async {
                controller.presentAlert(
                    "\(message)\n\n\(error.localizedDescription)"
                )
            }
        }
    }
}
