# Pusher 3.0.0 beta 1

A rewrite, not an update. The pipeline, the settings and the stored configuration
are all new.

## ⚠️ Your existing configuration will not be read

**2.x settings are not migrated.** After upgrading, Pusher starts with no
services configured, and they have to be added again.

This is deliberate rather than an oversight. 2.x kept one configuration per
built-in service (`BuiltInServices`, a dictionary keyed by service name) and the
same shape for custom ones. 3.0 has no such container: a service *type* and a
configured *instance* are different things, and the list of instances is an
ordered array — which is what makes it possible to add Bark twice, or to give two
Pushover accounts different app filters.

```
2.x                             3.0
BuiltInServices                  Services          an array of instances
  Bark     → { key, … }            ├─ Bark      { id, type, name, … }
  Pushover → { token, … }          ├─ Bark      { id, type, name, … }
CustomServices                   └─ Pushover  { id, type, name, … }
  webhook  → { url, … }          CustomServices    an array of definitions
                                   └─ webhook { id, name, script, … }
```

A migration would have to guess which of the new concepts each old entry maps to,
and the result would be a configuration nobody wrote. Starting clean is the
honest version of the same outcome.

**Note down your tokens before upgrading.** They are visible in 2.x under each
service, and are not readable from the new build.

## What is new

**Services are instances.** Any service type can be added any number of times,
each with its own name, configuration, app filter, device conditions and log.
Drag to reorder; that order is the order they are tried.

**Custom services are two things now.** A *service* is a definition — a
JavaScript script that decides what to send. An *instance* is a configured
destination that uses one. One script can back several instances, and editing it
changes all of them.

**JavaScript services.** Write the request yourself with `fetch`, `localStorage`
and a `bullet` object holding the notification. Set per-definition defaults for
thread and context isolation, timeout and response size limit.

**JavaScript hooks, per instance.** Two optional scripts — one when the
notification arrives, one after the app and device filters — that can rewrite it
or drop it. A hook cannot send; it decides.

**Shortcut services.** Run one of your Shortcuts, silently, with the notification
passed in as a dictionary. A guide on the instance page explains the one step
that is easy to miss, and offers a ready-made Shortcut.

**Import and export.** Services and instances can be written to plain JSON and
read back on another device, with or without the definitions they use.

## Requirements

iOS 15 or later. Rootless and roothide jailbreaks. **Rootful (iOS 14) is not
supported** — the Swift toolchain this is built with cannot target the 14.x SDK,
and rootless is what the supported devices run.

## Known limitations

- 2.x configuration is not read (above)
- A Shortcut service cannot carry the notification's icon or image into a run
  unless the instance asks for them; the payload gets large quickly
- The example Shortcut's bundled signature expires in November 2027, after which
  the app asks a signing service for a fresh one. That service is behind
  Cloudflare and is unreachable from some networks.
