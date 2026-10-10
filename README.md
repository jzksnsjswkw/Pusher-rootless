# Pusher-rootless

[简体中文](Docs/zh-Hans/README.md)

Rootless version of [NoahSaso/Pusher](https://github.com/NoahSaso/Pusher).

Supports iOS 15–16, roothide devices included. Built-in services: Bark, Feishu,
WeChat Work, Pushover, Pushbullet, IFTTT, Pusher Receiver and a generic webhook —
plus user-defined services, per-app overrides, device & sound lists, notification
settings conditions and a Chinese interface.

## Build

You need Theos and `com.opa334.altlist` from
[AltList](https://github.com/opa334/AltList).

The scheme must be named — the build stops without one, because a classic rootful
package is not something this repository produces.

```bash
# rootless
THEOS_PACKAGE_SCHEME=rootless make clean package
# roothide
THEOS_PACKAGE_SCHEME=roothide make clean package
```

Install to a device (set `THEOS_DEVICE_IP` / `THEOS_DEVICE_PORT` in the Makefile
first):

```bash
# rootless
THEOS_PACKAGE_SCHEME=rootless make clean do
# roothide
THEOS_PACKAGE_SCHEME=roothide make clean do
```

The code is all Swift; only `Sources/Hooks/*.xm` is Logos, because `%hook` /
`%orig` / `%init` have no Swift equivalent. Adding a built-in service is two
steps: write the type, then add a line to `addableServices` in
`Sources/Core/ServiceRegistry.swift`.

Layout:

```
Sources/
├── Core/                 the push pipeline (no UI)
│   ├── Services/         one file per push service (Bark / Feishu / WeChat / …)
│   └── Runtime/          ObjC runtime bridging (private APIs, method hooks)
├── Shared/               preference storage and logs
├── Hooks/                Logos hooks + bridging header
├── Preferences/          the settings UI (plists and images under Resources/)
└── Flipswitch/           the control-center switch
```

## Docs

- [Writing a new push service](Docs/en/new-push-service.md)
- UI strings live in
  `Sources/Preferences/Resources/zh-Hans.lproj/Localizable.strings`; English
  labels in the plists are localized automatically in the settings UI.
