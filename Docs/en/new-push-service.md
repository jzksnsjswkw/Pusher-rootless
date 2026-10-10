# Pusher — Writing a New Push Service

> For developers adding a new built-in push service to Pusher.
> [简体中文](../zh-Hans/新推送服务开发文档.md)

---

## 1. What you need to do (four steps)

1. Create `Sources/Core/Services/<Name>Service.swift`, implementing `PushService`.
2. Create `Sources/Preferences/Resources/<Name>.plist` — the settings page.
3. Add one line to `ServiceRegistry.addableServices`: `.init(<Name>Service.self)`.
4. Add a display name to `Sources/Preferences/Resources/zh-Hans.lproj/Localizable.strings` if needed.

No Makefile changes (Swift sources are picked up automatically), no `+load` registration.

---

## 2. What a service looks like

Bark, in full (`Sources/Core/Services/BarkService.swift`):

```swift
import Foundation

public enum BarkService: PushService {
    public static let serviceName = "Bark"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        let base = serverURL.isEmpty ? "https://api.day.app" : serverURL
        return (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/"
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        var infoDict: [String: Any] = [
            "title": context.displayTitle,
            "body": context.displayMessage,
        ]
        // Optional parameters: only sent when the user filled them in.
        for (prefKey, apiName) in parameters {
            let value = config.raw.string(prefKey) ?? ""
            if !value.isEmpty { infoDict[apiName] = value }
        }

        let urlString = config.raw.string(PrefKey.url, default: "")
            + config.raw.string(PrefKey.key, default: "")
        return withLogBody(
            PushRequest(urlString: urlString, infoDict: infoDict),
            infoDict
        )
    }

    public static func defaultPrefs() -> [String: Any] {
        ["serverURL": "https://api.day.app" /* plus one empty string per parameter */]
    }

    public static func defaultCustomAppPrefs() -> [String: Any] { [:] }
}
```

Writing a service is answering four questions:

| Question | Where you answer it |
| --- | --- |
| What is this service called | `serviceName` |
| Where does the push go | `url(...)` and the URL you assemble in `request(...)` |
| What does the request body look like | `request(context:config:)` |
| What does a new instance start with | `defaultPrefs()` |

---

## 3. What you get when a notification arrives

`request(context:config:)` receives the notification as `context` — **no SpringBoard
private classes involved**:

| Field | Meaning |
| --- | --- |
| `title` / `subtitle` / `message` | The bulletin's raw fields |
| `displayTitle` | `"AppName: title"` |
| `displayMessage` | Subtitle and message, joined as the bulletin would show them |
| `appID` / `appName` | The sending app's bundle ID / display name |
| `date` | When the notification arrived (never nil) |
| `isTest` | Whether this is a test push |
| `attachmentURL` | The attachment's file URL, `nil` when there is none |
| `iconImage` | The app's icon (lazily resolved — pricey, take it only if you need it) |

`config` is this instance's configuration. `config.raw` is a dictionary keyed by the
`key` of each row in your settings plist — whatever the user filled in is there.

---

## 4. The request you return

```swift
PushRequest(urlString: "https://...", infoDict: [...])
```

Defaults to `POST` with a JSON body. The other options:

```swift
var request = PushRequest(urlString: ..., infoDict: ...)
request.method = "GET"       // GET/HEAD: infoDict becomes the URL query
request.bodyType = "form"    // other methods default to json
```

- **Images**: put a `UIImage` straight into `infoDict`; it is Base64-encoded before
  sending.
- **Logs**: wrap the request with `withLogBody(request, infoDict)` — Base64 fields are
  replaced with `<image>` so the log stays readable. If your Base64 fields are not
  named `icon`/`image`, override `logImageDataProperties` with your own list.

---

## 5. The settings page

`Sources/Preferences/Resources/<Name>.plist`, one-to-one with instance storage:

```xml
<dict>
  <key>items</key>
  <array>
    <dict><key>cell</key><string>PSGroupCell</string><key>label</key><string>Credentials</string></dict>
    <dict>
      <key>cell</key><string>PSEditTextCell</string>
      <key>key</key><string>key</string>          <!-- config.raw["key"] -->
      <key>label</key><string>Key:</string>
    </dict>
    ...
  </array>
</dict>
```

Rules:

- Each value row's `key` **is** the field name in `config.raw`.
- Include an `App List` row (`NSPAppListController`) and an `App Customization` row
  (`NSPCustomizeAppsController`) — the app filter and the per-app overrides. The
  framework appends the shared tail (device conditions, notification settings, log,
  test push) automatically.
- The plist file name must equal `serviceName`.

Patterns worth copying:

| You want | Look at |
| --- | --- |
| A key field and a custom server | `Bark.plist` |
| A dropdown (auth mode and the like) | `Custom.plist` |
| Switches (include icon and the like) | `Pushover.plist` |
| A per-app override field | `Wechat.plist` |

---

## 6. Async: fetch a token first (like WeChat)

Override the async variant; you do not write the sync one:

```swift
public static func request(
    context: BulletinContext, config: ServiceConfig,
    completion: @escaping (PushRequest?) -> Void
) {
    fetchToken(config: config) { token in
        guard let token else { completion(nil); return }   // nil = skip this push
        completion(buildRequest(context: context, config: config, token: token))
    }
}
```

For token caching, see `WechatService`: keyed by `corpid|corpsecret`, a 60-second
safety margin, expiry honoured, concurrent fetches deduplicated (single-flight).

To react to the **response** (say token expired, errcode 40014), use a
`resendHandler`: the sender calls you back with each response, you hand back a fresh
request via `completion(newRequest, false)`, and the framework resends. Resends and
network retries share one budget, so this cannot loop forever.

---

## 7. Icons and images

Two declarations on the protocol:

```swift
public static var supportsIcon: Bool { true }    // payload carries an icon field
public static var supportsImage: Bool { true }   // payload carries an image field
```

- Only when a capability is declared does the instance page show the matching
  "include icon" / "include image" switches.
- Bark declares neither: its body is its own `title`/`body` with nowhere for the
  shared fields, and its `image` parameter takes an image **URL**, not Base64.
- When the user turns a switch on, `baseInfoDict(...)` puts the icon/image into the
  shared data dict (used by IFTTT, Pusher Receiver and custom webhooks). A service
  that builds its own body takes the icon from `context.iconImage` itself.

---

## 8. Checklist

- [ ] `Sources/Core/Services/<Name>Service.swift` implements `PushService`
- [ ] One line added to `ServiceRegistry.addableServices`
- [ ] `serviceName` = the plist file name
- [ ] `request(context:config:)` assembles the URL, builds the body, wraps the log
      with `withLogBody`
- [ ] Every value row's `key` in the plist matches what you read from `config.raw`
- [ ] The plist has `App List` and `App Customization` rows
- [ ] `defaultPrefs()` defaults every field (an empty string = not sent)
- [ ] `THEOS_PACKAGE_SCHEME=roothide make package` builds

---

## 9. Appendix: the JS way

If you do not want to write Swift, users can define a service themselves in the app
(Services → + → write a script). The script gets the same `bullet` object and a
`push()` function. Writing Swift is only for a service you want **built in**, working
out of the box for everyone. The AI prompt for generating scripts is in the app,
under Guide → Copy AI Prompt.
