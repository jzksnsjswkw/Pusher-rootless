#import <Foundation/Foundation.h>

/// Publishes a notification as if the app named in `sectionID` had sent it.
///
/// SpringBoard is the only process that can put a banner on the screen, and
/// `BBServer` is the object that does it. This is the entry point the Preferences
/// side calls over distributed messaging: the user composes the notification
/// there, and SpringBoard publishes it here so it arrives with the right app's
/// name and icon rather than with Pusher's.
///
/// Returns whether the bulletin was published. A notification for an app
/// SpringBoard has no section for would be published and then drawn as
/// "Unknown App", which is worse than not sending it.
/// - Parameter simSlot: the card the notification claims to have arrived on, or
///   `0` for a notification that did not arrive on one.
FOUNDATION_EXPORT BOOL PusherPublishBanner(NSString *sectionID,
                                          NSString *title,
                                          NSString *subtitle,
                                          NSString *message,
                                          NSString *attachmentPath,
                                          long long simSlot,
                                          NSString *simPhone,
                                          NSString *simLabel);

/// Why the last ``PusherPublishBanner`` returned `NO`, or `nil` when it worked.
///
/// Each step depends on a private class that not every iOS version ships, so the
/// caller gets the step that failed rather than a single "could not publish".
FOUNDATION_EXPORT NSString *PusherPublishBannerFailure;
