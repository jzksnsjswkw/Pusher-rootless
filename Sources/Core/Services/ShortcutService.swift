import Foundation

/// Runs one of the user's Shortcuts, silently, with the notification as input.
///
/// This is the only service that does not send an HTTP request. What it does
/// instead is described in `ShortcutRunner.h`, which owns the private-API work;
/// this file is the part that fits into the pipeline: it names the shortcut,
/// turns the bulletin into the payload a Shortcut can read, and hands both over.
///
/// A Shortcut is the graphical counterpart to a JavaScript service: the same
/// idea — decide what to send, in something the user edits — with the editing
/// done by dragging actions instead of typing code. It is a separate service type
/// rather than a mode of the script one because the two share no storage, no
/// editor and no execution path.
public enum ShortcutService: PushService {
    public static let serviceName = "Shortcut"

    /// Both are carried, as Base64 in the payload dictionary.
    ///
    /// That is a real trade: the text goes through a `WFContentItem`, and a
    /// picture makes it tens of kilobytes that are decoded again before the
    /// Shortcut can use them. It is worth it because a Shortcut has no other way
    /// to reach the icon or the attachment — unlike a webhook, which can fetch
    /// the URL the payload would otherwise have to carry. A Shortcut that wants
    /// neither can switch them off, and a Shortcut that wants only the text
    /// should.
    public static var supportsIcon: Bool { true }
    public static var supportsImage: Bool { true }

    /// No URL: the request is a shortcut run, not a fetch.
    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        ""
    }

    /// Everything the switches on the instance page store.
    ///
    /// `supportsIcon`/`supportsImage` say the payload *may* carry them; without
    /// these defaults and the two readers below, nothing ever does — the
    /// switches would write values no code consults, and appear to work while
    /// changing nothing.
    public static func defaultPrefs() -> [String: Any] {
        [
            ShortcutPrefKey.shortcutName: "",
            PrefKey.includeIcon: false,
            PrefKey.includeImage: true,
            PrefKey.imageMaxWidth: Pusher.defaultMaxWidth,
            PrefKey.imageMaxHeight: Pusher.defaultMaxHeight,
            PrefKey.imageShrinkFactor: Pusher.defaultShrinkFactor,
        ]
    }

    public static func defaultCustomAppPrefs() -> [String: Any] {
        [
            PrefKey.includeIcon: false,
            PrefKey.includeImage: true,
            PrefKey.imageMaxWidth: Pusher.defaultMaxWidth,
            PrefKey.imageMaxHeight: Pusher.defaultMaxHeight,
            PrefKey.imageShrinkFactor: Pusher.defaultShrinkFactor,
        ]
    }

    /// Read from the instance, exactly as the webhook does.
    ///
    /// The defaults above are the *type's*; the value in effect is whatever this
    /// instance has, which is what the switches write.
    public static func shouldIncludeIcon(config: ServiceConfig) -> Bool {
        config.raw.bool(PrefKey.includeIcon)
    }

    public static func shouldIncludeImage(config: ServiceConfig) -> Bool {
        config.raw.bool(PrefKey.includeImage)
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        let name = (config.raw.string(ShortcutPrefKey.shortcutName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            PusherLog.info("[Shortcut] no shortcut selected")
            return nil
        }

        let payload = self.payload(context: context, config: config)
        guard let json = encode(payload) else {
            PusherLog.info("[Shortcut] could not encode payload")
            return nil
        }

        // A shortcut run is not a fetch. The request carries the shortcut name
        // and the JSON in `state` — the field meant for information a service
        // hands to its own delivery path — and `RequestSender`'s shortcut branch
        // performs the run instead of a URLSession task.
        let request = PushRequest(urlString: "", infoDict: [:])
        request.state[ShortcutState.shortcutName] = name
        request.state[ShortcutState.input] = json
        return request
    }

    /// The dictionary a Shortcut receives.
    ///
    /// Built from the shared payload, so the field names and values are the ones
    /// every other service sends: a user who has written a script already knows
    /// what to expect, and an AI asked to write either one sees one vocabulary.
    ///
    /// Icon and image ride along when the instance asks for them, as Base64 in
    /// the same fields every other service uses. `date` keeps whatever format the
    /// instance configured.
    private static func payload(context: BulletinContext, config: ServiceConfig) -> [String: Any] {
        baseInfoDict(context: context, config: config)
    }

    private static func encode(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Where the shortcut name and its input ride on the request.
enum ShortcutState {
    static let shortcutName = "shortcutName"
    static let input = "shortcutInput"
}

/// This service's own preference keys.
enum ShortcutPrefKey {
    /// The name of the Shortcut to run, as it appears in the Shortcuts app.
    static let shortcutName = "shortcutName"
}
